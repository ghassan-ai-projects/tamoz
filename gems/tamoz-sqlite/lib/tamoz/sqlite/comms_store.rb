# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

require_relative 'wire'
require_relative 'comms_store_rows'
require_relative 'comms_outbox'
require_relative 'comms_routes'

module Tamoz
  module SQLite
    # The channel store facade (design §13, plan slice C). Implements the
    # structural Tamoz::Comms::CommsStore contract WITHOUT referencing the
    # contract gem (dependency rule 9): wire-form hashes in, wire-form hashes
    # out, and the integration layer verifies the CONTRACT_VERSION pair.
    #
    # Admission shares the request-inbox enqueue seam inside ONE transaction
    # (poll → admit → enqueue in the same runtime database, exactly like the
    # scheduler); prompt consumption inserts its decision in the same
    # transaction (ADR-043). Outbox and route operations delegate to the
    # composed stores so every file stays under the size contract.
    #
    # The operation labels are the kill-harness addresses (BoundaryRegistry);
    # a crash before commit leaves `old` state, after commit `new` state.
    # :reek:LongParameterList, :reek:UnusedParameters, :reek:DataClump
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:NilCheck
    # :reek:TooManyStatements -- the primitives mirror the §13 contract
    #   signatures and their one-transaction bodies; splitting them would
    #   fragment the durable operations.
    # :reek:TooManyMethods -- one primitive per table seam is the contract.
    # rubocop:disable Metrics/ParameterLists, Metrics/BlockLength -- the §13 contract signatures and their one-transaction blocks.
    # rubocop:disable Metrics/ClassLength -- the store is one facade over the
    #   §13 contract; splitting it would scatter the transaction boundaries.
    # rubocop:disable Metrics/MethodLength -- admit_and_enqueue is one atomic
    #   admission (inbound + request + enqueue); splitting it would open the
    #   crash window the design closes with a single transaction.
    class CommsStore
      include CommsStoreRows

      CONTRACT_VERSION = 2
      REQUEST_OPERATION = 'turn'
      REQUEST_DELIVERY = 'queue'
      DEFAULT_NAMESPACE = '[]'
      HISTORY_LIMIT = 12
      HISTORY_TEXT_CHARACTERS = 500

      def initialize(adapter:, checkpoints: nil)
        @adapter = adapter
        @checkpoints = checkpoints
        @outbox = CommsOutbox.new(adapter:)
        @routes = CommsRoutes.new(adapter:)
      end

      # ===== surfaces =====

      def deploy_surface(descriptor_wire, now:)
        transaction('comms.surface.deploy') do |txn|
          existing = txn.first('comms.surface.deploy.existing', <<~SQL, [descriptor_wire.fetch('surface_id')])
            SELECT revision FROM tamoz_comms_surfaces WHERE surface_id = ?
          SQL
          next :duplicate if existing && existing[0] >= descriptor_wire.fetch('revision')

          upsert_surface!(txn, descriptor_wire, now)
          :deployed
        end
      end

      def surface(surface_id:)
        read('comms.surface.read') do |txn|
          row = txn.first('comms.surface.read', <<~SQL, [surface_id])
            SELECT descriptor_json FROM tamoz_comms_surfaces WHERE surface_id = ?
          SQL
          row && JSON.parse(row.fetch(0))
        end
      end

      # ===== admission =====

      # Admit ONE inbound update AND enqueue its turn in one transaction. The
      # derived request id is the dedup key; a replayed update is :duplicate.
      # `bot_id` is the authenticated surface identity the update arrived on.
      # Intake is bounded by the surface's outbox capacity (design §12,
      # invariant 57): pending+claimed deliveries plus the reservations of
      # admitted-but-unfinished requests must stay under `capacity`, so the
      # reserved terminal row can always append.
      # `history` is the conversation transcript so far (see
      # `conversation_history`); it rides inside the payload's `task` entry
      # (the same Hash shape a cancel payload uses, since payload keys map
      # onto state channels one-to-one) so the turn is planned with the
      # thread's context, not with one message alone.
      # :reek:LongParameterList -- the admission binds every fact design §6
      #   makes durable in one transaction.
      def admit_and_enqueue(envelope_wire, surface_id:, bot_id:, thread:, profile_id:, reservation:, capacity:, now:,
                            history: [])
        transaction('comms.admit.enqueue') do |txn|
          next :duplicate if inbound_row(txn, envelope_wire, bot_id)
          next :capacity_refused if capacity_saturated?(txn, surface_id, reservation, capacity)

          insert_inbound!(txn, envelope_wire, bot_id:, disposition: 'request', reason: 'accepted', now:)
          request_id = request_id_for(envelope_wire, bot_id)
          request_binds = [request_id, surface_id, envelope_wire.fetch('surface_revision'),
                           envelope_wire.fetch('conversation_id'), thread, profile_id,
                           reservation, now_ms(now), now_ms(now)]
          txn.execute('comms.admit.request.upsert', <<~SQL, request_binds)
            INSERT OR IGNORE INTO tamoz_comms_requests (
              request_id, surface_id, surface_revision, conversation_id,
              thread_id, profile_id, reservation, projection_state,
              created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'admitted', ?, ?)
          SQL
          payload_bytes = @checkpoints.checkpoint_codec.dump_request_payload(
            REQUEST_OPERATION, turn_payload(envelope_wire.fetch('text'), history)
          )
          payload_digest = Wire.digest(payload_bytes, domain: 'tamoz.sqlite.request_payload')
          input_digest = Wire.digest(
            JSON.generate([REQUEST_OPERATION, REQUEST_DELIVERY, payload_bytes]),
            domain: 'tamoz.sqlite.request'
          )
          @checkpoints.enqueue_request_in_transaction!(
            txn, thread:, encoded_namespace: DEFAULT_NAMESPACE, id: request_id,
                 operation_text: REQUEST_OPERATION, delivery_text: REQUEST_DELIVERY,
                 payload_bytes:, payload_digest:, input_digest:
          )
          :enqueued
        end
      end

      # Record a non-request disposition (ignored/rejected/quarantined) durably.
      # rubocop:disable Lint/UnusedMethodArgument -- `surface_id` keeps the §13
      # contract signature; the inbound table derives the surface from the
      # envelope wire.
      def disposition_only(envelope_wire, surface_id:, bot_id:, disposition:, reason:, now:)
        transaction('comms.admit.disposition') do |txn|
          next :duplicate if inbound_row(txn, envelope_wire, bot_id)

          insert_inbound!(txn, envelope_wire, bot_id:, disposition:, reason:, now:)
          :recorded
        end
      end
      # rubocop:enable Lint/UnusedMethodArgument

      # The admission capacity gate (invariant 57): the new reservation must
      # fit alongside pending+claimed deliveries and the other open
      # reservations.
      def capacity_saturated?(txn, surface_id, reservation, capacity)
        pending_claimed_count(txn, surface_id) + open_reservations(txn, surface_id) + reservation > capacity
      end

      # A bare task string for a first contact; once the conversation has a
      # transcript the text nests with it under the task Hash — the shape the
      # graph's payload-to-channel mapping tolerates (payload keys map onto
      # state channels one-to-one, and `task` already carries Hashes).
      # :reek:UtilityFunction -- pure payload shaping for the admission above.
      def turn_payload(text, history)
        return { 'task' => text } if history.empty?

        { 'task' => { 'text' => text, 'conversation' => history } }
      end

      # ===== poll state =====

      # One fenced poller per authenticated bot (design §13): a live lease is
      # not claimable by a second poller; an expired lease is recoverable.
      def acquire_poller_lease(surface_id:, bot_id:, owner:, fence:, ttl_s:, now:)
        transaction('comms.poll.lease') do |txn|
          current = txn.first('comms.poll.lease.current', <<~SQL, [bot_id])
            SELECT poller_owner_id, poller_fence, poller_expires_at_ms
            FROM tamoz_comms_poll_state WHERE bot_id = ?
          SQL
          next :not_acquirable if current && current[2] && current[2] > now_ms(now) && current[0] != owner

          upsert_poller!(txn, surface_id:, bot_id:, owner:, fence:, expires_at_ms: now_ms(now) + (ttl_s * 1000), now:)
          :acquired
        end
      end

      # Persist the candidate next_offset ONLY after the returned prefix is
      # durable. Never regresses: an offset behind the stored one is :behind,
      # and a nil candidate (an empty poll prefix) is :unchanged — it must
      # never clobber the durable offset.
      def persist_next_offset(surface_id:, bot_id:, next_offset:, now:)
        transaction('comms.poll.offset') do |txn|
          next :unchanged if next_offset.nil?

          stored = txn.first('comms.poll.offset.stored', <<~SQL, [bot_id])
            SELECT next_offset FROM tamoz_comms_poll_state WHERE bot_id = ?
          SQL
          next :behind if stored && !stored[0].nil? && stored[0] >= next_offset

          txn.execute('comms.poll.offset.upsert', <<~SQL, [bot_id, surface_id, next_offset, now_ms(now)])
            INSERT INTO tamoz_comms_poll_state (
              bot_id, surface_id, next_offset, updated_at_ms
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(bot_id) DO UPDATE SET
              next_offset = excluded.next_offset, updated_at_ms = excluded.updated_at_ms
          SQL
          :persisted
        end
      end

      # The durable next_offset for one bot (nil when never persisted).
      def poll_offset(bot_id:)
        read('comms.poll.offset.read') do |txn|
          txn.scalar('comms.poll.offset.read', <<~SQL, [bot_id])
            SELECT next_offset FROM tamoz_comms_poll_state WHERE bot_id = ?
          SQL
        end
      end

      # Release this gateway's poller lease (idempotent — only releases when
      # the fence is ours, so a crashed gateway's lease expires on its own).
      def release_poller_lease(bot_id:, owner:, fence:)
        transaction('comms.poll.release') do |txn|
          txn.execute('comms.poll.release', <<~SQL, [bot_id, owner, fence])
            UPDATE tamoz_comms_poll_state
            SET poller_owner_id = NULL, poller_fence = NULL, poller_expires_at_ms = NULL
            WHERE bot_id = ? AND poller_owner_id = ? AND poller_fence = ?
          SQL
          :released
        end
      end

      # ===== outbox and routes (delegated) =====

      def append_delivery(delivery_wire, surface_id:, capacity:, now:, reserved_request_id: nil)
        @outbox.append_delivery(delivery_wire, surface_id:, capacity:,
                                               reserved_request_id:, now:)
      end

      # Terminal projection is durable; release the request's reservation so
      # its slots return to intake (design §12: unused slots release only
      # after terminal projection is durable).
      def complete_request(thread_id:, request_id:)
        transaction('comms.request.complete') do |txn|
          txn.execute('comms.request.complete', <<~SQL, [thread_id, request_id])
            UPDATE tamoz_comms_requests SET projection_state = 'completed'
            WHERE thread_id = ? AND request_id = ? AND projection_state = 'admitted'
          SQL
          txn.changes == 1 ? :released : :not_admitted
        end
      end

      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        @outbox.claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
      end

      def reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:, global_messages_per_s:, now:)
        @outbox.reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:,
                                      global_messages_per_s:, now:)
      end

      def release_delivery_claim(delivery_id:, owner:, fence:, now:)
        @outbox.release_delivery_claim(delivery_id:, owner:, fence:, now:)
      end

      def mark_delivery_send_started(delivery_id:, owner:, fence:, now:)
        @outbox.mark_delivery_send_started(delivery_id:, owner:, fence:, now:)
      end

      def reconcile_expired_deliveries(now:)
        @outbox.reconcile_expired_deliveries(now:)
      end

      def defer_delivery(surface_id:, conversation_id:, not_before:, now:)
        @outbox.defer_delivery(surface_id:, conversation_id:, not_before:, now:)
      end

      def conversation_status(surface_id:, conversation_id:)
        read('comms.conversation.status') do |txn|
          route = txn.first('comms.conversation.status.route', <<~SQL, [surface_id, conversation_id])
            SELECT thread_id FROM tamoz_comms_conversations
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          next nil unless route

          open_requests = txn.scalar('comms.conversation.status.requests', <<~SQL, [surface_id, conversation_id]).to_i
            SELECT COUNT(*) FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
          SQL
          {
            'thread_id' => route.fetch(0),
            'state' => open_requests.positive? ? 'accepted' : 'idle',
            'open_requests' => open_requests
          }
        end
      end

      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        @outbox.bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
      end

      # ===== conversation history =====

      # The recent transcript of one conversation, oldest first, for the
      # turn's planning context: user lines are the admitted requests' task
      # payloads (the inbound table stores hashes, never text), assistant
      # lines are the journaled terminal deliveries the correspondent
      # actually saw. Bounded twice — `limit` entries, each truncated —
      # because the transcript rides the request payload into a model prompt.
      def conversation_history(surface_id:, conversation_id:, limit: HISTORY_LIMIT)
        entries = recent_request_tasks(surface_id:, conversation_id:, limit:) +
                  recent_terminal_deliveries(surface_id:, conversation_id:, limit:)
        entries.sort_by { |entry| entry.fetch(:at) }.last(limit).map do |entry|
          { 'role' => entry.fetch(:role), 'text' => entry.fetch(:text) }
        end
      end

      def outbox_rows(surface_id:, statuses:, limit: 500)
        @outbox.outbox_rows(surface_id:, statuses:, limit:)
      end

      def mark_delivery(delivery_id:, status:, now:, receipt: nil)
        @outbox.mark_delivery(delivery_id:, status:, receipt:, now:)
      end

      def resolve_delivery(delivery_id:, status:, now:)
        @outbox.resolve_delivery(delivery_id:, status:, now:)
      end

      def bind_correspondent(binding_wire, now:)
        @routes.bind_correspondent(binding_wire, now:)
      end

      def revoke_binding(correspondent_id:, surface_id:, reason:, now:)
        @routes.revoke_binding(correspondent_id:, surface_id:, reason:, now:)
      end

      def binding(correspondent_id:, surface_id:, version: nil)
        @routes.binding(correspondent_id:, surface_id:, version:)
      end

      def bind_conversation(conversation_wire, now:)
        @routes.bind_conversation(conversation_wire, now:)
      end

      def conversation(surface_id:, conversation_id:)
        @routes.conversation(surface_id:, conversation_id:)
      end

      # The conversation a thread routes to (via its most recent admission),
      # for delivery projection (design §13).
      def request_conversation(thread_id:)
        read('comms.request.conversation') do |txn|
          row = txn.first('comms.request.conversation', <<~SQL, [thread_id])
            SELECT surface_id, conversation_id FROM tamoz_comms_requests
            WHERE thread_id = ? ORDER BY created_at_ms DESC LIMIT 1
          SQL
          row && { 'surface_id' => row[0], 'conversation_id' => row[1] }
        end
      end

      # ===== prompts =====

      # Insert one approval prompt (inactive until its send receipt is
      # durable; ADR-043). Idempotent on reference_digest.
      def insert_prompt(prompt_wire)
        transaction('comms.prompt.insert') do |txn|
          existing = txn.first('comms.prompt.insert.existing', <<~SQL, [prompt_wire.fetch('reference_digest')])
            SELECT 1 FROM tamoz_comms_approval_prompts WHERE reference_digest = ?
          SQL
          next :duplicate if existing

          txn.execute('comms.prompt.insert', <<~SQL, prompt_binds(prompt_wire))
            INSERT INTO tamoz_comms_approval_prompts (
              reference_digest, surface_id, surface_revision, thread_id,
              occurrence_id, interrupt_digest, required_evidence,
              correspondent_id, conversation_id, prompt_receipt, status,
              created_at_ms, activated_at_ms, consumed_at_ms, expires_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          :inserted
        end
      end

      # Activate one approval prompt only after its send receipt is durable.
      def activate_prompt(reference_digest:, now:)
        transaction('comms.prompt.activate') do |txn|
          row = txn.first('comms.prompt.activate.state', <<~SQL, [reference_digest])
            SELECT status, expires_at_ms FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          next :missing unless row
          next :expired if row[1] <= now_ms(now)
          next :already_active if row[0] == 'active'

          txn.execute('comms.prompt.activate', <<~SQL, [now_ms(now), reference_digest])
            UPDATE tamoz_comms_approval_prompts
            SET status = 'active', activated_at_ms = ?
            WHERE reference_digest = ? AND status = 'inactive'
          SQL
          txn.changes == 1 ? :activated : :not_consumable
        end
      end

      # Consume one ACTIVE prompt and insert its decision in ONE transaction:
      # a replayed reference can never be consumed twice, and a consumed
      # prompt never leaves a decision behind (design §9, ADR-043).
      def consume_prompt(reference_digest:, decision_wire:, now:)
        transaction('comms.prompt.consume') do |txn|
          row = txn.first('comms.prompt.consume.state', <<~SQL, [reference_digest])
            SELECT status, expires_at_ms FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          next :missing unless row
          next :expired if row[1] <= now_ms(now)

          txn.execute('comms.prompt.consume', <<~SQL, [now_ms(now), reference_digest])
            UPDATE tamoz_comms_approval_prompts
            SET status = 'consumed', consumed_at_ms = ?
            WHERE reference_digest = ? AND status = 'active'
          SQL
          next :not_consumable unless txn.changes == 1

          CommsDecisionStore.new(adapter: @adapter).insert_decision_in_transaction!(txn, decision_wire)
          :consumed
        end
      end

      def prompt(reference_digest:)
        read('comms.prompt.read') do |txn|
          row = txn.first('comms.prompt.read', <<~SQL, [reference_digest])
            SELECT #{PROMPT_COLUMNS.join(', ')} FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          row && normalize_prompt_row(PROMPT_COLUMNS.zip(row).to_h)
        end
      end

      # A pre-migration in-flight prompt carries NULL required_evidence
      # (MIGRATION_9): it reads as filesystem_operator — the safe default —
      # so a legacy prompt is never under-gated (INV-E/INV-D).
      # :reek:UtilityFunction -- a pure row-shape normalization; it belongs
      #   next to the read that owns the NULL default, not in the rows module.
      def normalize_prompt_row(row)
        row['required_evidence'] = 'filesystem_operator' if row['required_evidence'].nil?
        row
      end

      # ===== operator surface (COMMS_DESIGN §14) =====

      def surfaces
        read('comms.surface.list') do |txn|
          txn.rows('comms.surface.list', <<~SQL).map { |row| SURFACE_COLUMNS.zip(row).to_h }
            SELECT #{SURFACE_COLUMNS.join(', ')} FROM tamoz_comms_surfaces
            ORDER BY surface_id
          SQL
        end
      end

      def bindings(surface_id:)
        read('comms.binding.list') do |txn|
          txn.rows('comms.binding.list', <<~SQL, [surface_id]).map { |row| BINDING_COLUMNS.zip(row).to_h }
            SELECT #{BINDING_COLUMNS.join(', ')} FROM tamoz_comms_bindings
            WHERE surface_id = ? ORDER BY bound_at_ms DESC
          SQL
        end
      end

      def conversations(surface_id:)
        read('comms.route.list') do |txn|
          txn.rows('comms.route.list', <<~SQL, [surface_id]).map { |row| ROUTE_COLUMNS.zip(row).to_h }
            SELECT #{ROUTE_COLUMNS.join(', ')} FROM tamoz_comms_conversations
            WHERE surface_id = ? ORDER BY bound_at_ms DESC
          SQL
        end
      end

      # The active binding that admitted one conversation's correspondent
      # (the prompt needs the correspondent to scope its single-use digest).
      def binding_by_conversation(surface_id:, conversation_id:)
        bindings(surface_id:).find do |binding|
          binding.fetch('conversation_id') == conversation_id && binding.fetch('status') == 'active'
        end
      end

      def poll_state(bot_id:)
        read('comms.poll.state') do |txn|
          row = txn.first('comms.poll.state', <<~SQL, [bot_id])
            SELECT #{POLL_COLUMNS.join(', ')} FROM tamoz_comms_poll_state
            WHERE bot_id = ?
          SQL
          row && POLL_COLUMNS.zip(row).to_h
        end
      end

      # Outbox depth per status for one surface (design §14: the status
      # section shows pending depth and `:unknown` deliveries).
      def outbox_counts(surface_id:)
        read('comms.outbox.counts') do |txn|
          txn.rows('comms.outbox.counts', <<~SQL, [surface_id]).to_h { |row| [row[0], row[1]] }
            SELECT status, COUNT(*) FROM tamoz_comms_outbox
            WHERE surface_id = ? GROUP BY status
          SQL
        end
      end

      # The comms safety counters (design §16), derived from durable rows:
      # unauthorized admissions are `request` rows with no active binding
      # anywhere for that correspondent, and chat grants are membership rows
      # that reached `request` (impossible in v1 — admission ignores
      # membership, but the count is derived, not assumed).
      def admission_audit_counts
        read('comms.audit.counts') do |txn|
          {
            'unauthorized_inbound_admissions' => txn.scalar('comms.audit.unauthorized', <<~SQL),
              SELECT COUNT(*) FROM tamoz_comms_inbound i
              WHERE i.disposition = 'request'
                AND NOT EXISTS (
                  SELECT 1 FROM tamoz_comms_bindings b
                  WHERE b.surface_id = i.surface_id AND b.correspondent_id = i.correspondent_id
                    AND b.status = 'active')
            SQL
            'chat_grants' => txn.scalar('comms.audit.chat_grants', <<~SQL)
              SELECT COUNT(*) FROM tamoz_comms_inbound
              WHERE kind = 'membership' AND disposition = 'request'
            SQL
          }
        end
      end

      # ===== pairing (design §7) =====

      # All pairing challenge rows, optionally filtered by status. The digest
      # is stored, never the plaintext code.
      def pairing_challenges(status: nil)
        read('comms.pairing.list') do |txn|
          sql = "SELECT #{PAIRING_COLUMNS.join(', ')} FROM tamoz_comms_pairing_challenges"
          binds = []
          unless status.nil?
            sql << ' WHERE status = ?'
            binds << status
          end
          sql << ' ORDER BY created_at_ms DESC'
          txn.rows('comms.pairing.list', sql, binds).map { |row| PAIRING_COLUMNS.zip(row).to_h }
        end
      end

      # Store the challenge digest for one unbound sender (idempotent on the
      # digest; the plaintext code travels to the sender exactly once).
      def insert_pairing_challenge(digest:, surface_id:, correspondent_id:, conversation_id:, expires_at:, now:)
        transaction('comms.pairing.insert') do |txn|
          binds = [digest, surface_id, correspondent_id, conversation_id, now_ms(expires_at), now_ms(now)]
          txn.execute('comms.pairing.insert', <<~SQL, binds)
            INSERT OR IGNORE INTO tamoz_comms_pairing_challenges (
              challenge_digest, surface_id, correspondent_id, conversation_id,
              status, attempts, expires_at_ms, created_at_ms
            ) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
          SQL
          txn.changes == 1 ? :inserted : :duplicate
        end
      end

      # Consume ONE pending challenge and write its binding in one transaction
      # (design §7): a crash between the two would leave a consumed challenge
      # that grants nothing. The caller verifies the code against the digest
      # and builds the binding wire; this method is the atomic commit.
      def approve_pairing(challenge_digest:, binding_wire:, now:)
        transaction('comms.pairing.approve') do |txn|
          txn.execute('comms.pairing.approve.consume', <<~SQL, [challenge_digest])
            UPDATE tamoz_comms_pairing_challenges SET status = 'consumed'
            WHERE challenge_digest = ? AND status = 'pending'
          SQL
          next :missing unless txn.changes == 1

          outcome = @routes.bind_correspondent_in_transaction!(txn, binding_wire, now:)
          next :already_bound unless outcome == :bound

          :approved
        end
      end

      private

      def recent_request_tasks(surface_id:, conversation_id:, limit:)
        rows = read('comms.history.requests') do |txn|
          txn.rows('comms.history.requests', <<~SQL, [surface_id, conversation_id, limit])
            SELECT request_id, thread_id, created_at_ms FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ?
            ORDER BY created_at_ms DESC LIMIT ?
          SQL
        end
        rows.filter_map do |request_id, thread_id, at|
          task = request_task(request_id, thread_id)
          task && { role: 'user', text: task[0, HISTORY_TEXT_CHARACTERS], at: }
        end
      end

      # The task text of one admitted request, read back from the graph inbox
      # payload. A channel turn with history nests the text under the task
      # Hash; any other non-text turn (a cancel or redirect payload) has no
      # transcript line, and a row that cannot be read back must not take the
      # admission down with it.
      def request_task(request_id, thread_id)
        request = @checkpoints.fetch_request(thread_id:, request_id:, namespace: [])
        task = request&.payload&.fetch('task', nil)
        task = task.fetch('text', nil) if task.is_a?(Hash)
        task.is_a?(String) ? task : nil
      rescue StandardError
        nil
      end

      def recent_terminal_deliveries(surface_id:, conversation_id:, limit:)
        rows = read('comms.history.deliveries') do |txn|
          txn.rows('comms.history.deliveries', <<~SQL, [surface_id, conversation_id, limit])
            SELECT text, created_at_ms FROM tamoz_comms_outbox
            WHERE surface_id = ? AND conversation_id = ? AND journaled = 1
              AND kind IN ('answer', 'failed', 'stopped', 'blocked') AND part_index = 0
            ORDER BY created_at_ms DESC LIMIT ?
          SQL
        end
        rows.map do |text, at|
          { role: 'assistant', text: text[0, HISTORY_TEXT_CHARACTERS], at: }
        end
      end

      def transaction(operation, &)
        @adapter.__send__(:transaction, operation:, &)
      end

      def read(operation, &)
        @adapter.__send__(:read, operation:, &)
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/BlockLength
# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/MethodLength
