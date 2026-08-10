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
    # :reek:LongParameterList -- the primitives mirror the §13 contract
    #   signatures; splitting them would fragment the durable operations.
    # :reek:TooManyMethods -- one primitive per table seam is the contract.
    # rubocop:disable Metrics/ParameterLists, Metrics/BlockLength -- the §13 contract signatures and their one-transaction blocks.
    # rubocop:disable Metrics/MethodLength -- admit_and_enqueue is one atomic
    #   admission (inbound + request + enqueue); splitting it would open the
    #   crash window the design closes with a single transaction.
    class CommsStore
      include CommsStoreRows

      CONTRACT_VERSION = 1
      REQUEST_OPERATION = 'turn'
      REQUEST_DELIVERY = 'queue'
      DEFAULT_NAMESPACE = '[]'

      def initialize(adapter:, checkpoints:)
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
      # :reek:LongParameterList -- the admission binds every fact design §6
      #   makes durable in one transaction.
      def admit_and_enqueue(envelope_wire, surface_id:, bot_id:, thread:, profile_id:, reservation:, now:)
        transaction('comms.admit.enqueue') do |txn|
          next :duplicate if inbound_row(txn, envelope_wire, bot_id)

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
          payload = { 'task' => envelope_wire.fetch('text') }
          payload_bytes = @checkpoints.checkpoint_codec.dump_request_payload(REQUEST_OPERATION, payload)
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
      # durable. Never regresses: an offset behind the stored one is :behind.
      def persist_next_offset(surface_id:, bot_id:, next_offset:, now:)
        transaction('comms.poll.offset') do |txn|
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

      # ===== outbox and routes (delegated) =====

      def append_delivery(delivery_wire, surface_id:, capacity:, now:)
        @outbox.append_delivery(delivery_wire, surface_id:, capacity:, now:)
      end

      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        @outbox.claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
      end

      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        @outbox.bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
      end

      def outbox_rows(surface_id:, statuses:, limit: 500)
        @outbox.outbox_rows(surface_id:, statuses:, limit:)
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
          row && PROMPT_COLUMNS.zip(row).to_h
        end
      end

      private

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
# rubocop:enable Metrics/MethodLength
