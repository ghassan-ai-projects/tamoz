# frozen_string_literal: true

require 'forwardable'
require 'json'

require 'tamoz/core'

require_relative 'wire'
require_relative 'comms_store_rows'
require_relative 'comms_outbox'
require_relative 'comms_outbox_reads'
require_relative 'comms_pacing'
require_relative 'comms_routes'
require_relative 'comms_inbound'
require_relative 'comms_polling'
require_relative 'comms_requests'
require_relative 'comms_request_facts'
require_relative 'comms_status'
require_relative 'comms_history'
require_relative 'comms_prompts'
require_relative 'comms_pairing'

module Tamoz
  module SQLite
    # The channel store facade (design §13, plan slice C). Implements the
    # structural Tamoz::Comms::CommsStore contract WITHOUT referencing the
    # contract gem (dependency rule 9): wire-form hashes in and out, plus the
    # contract's small values read by their fields (a lease's owner and fence,
    # a turn's thread and payload); the integration layer verifies the
    # CONTRACT_VERSION pair.
    #
    # Each operation lives in the collaborator that owns its tables; every
    # durable operation is one transaction there (admission shares the
    # request-inbox enqueue seam; prompt consumption inserts its decision).
    # The operation labels are the kill-harness addresses (BoundaryRegistry);
    # a crash before commit leaves `old` state, after commit `new` state.
    class CommsStore
      extend Forwardable
      include CommsStoreRows

      CONTRACT_VERSION = 4
      SURFACE_COLUMNS = %w[
        surface_id revision definition_digest descriptor_json created_at_ms
        updated_at_ms
      ].freeze

      def_delegators :@inbound, :admit_and_enqueue, :admit_and_enqueue_answer, :inbound_observed?, :disposition_only
      def_delegators :@polling, :acquire_poller_lease, :persist_next_offset, :poll_offset, :release_poller_lease,
                     :poll_state
      def_delegators :@requests, :complete_request, :cancellation_requested?, :working_conversations,
                     :open_request_targets, :request_cancellation, :mark_cancellation_observed,
                     :request_conversation, :requests_by_reference
      def_delegators :@status, :conversation_status, :request_status
      def_delegators :@facts, :task_state_for
      def_delegators :@history, :conversation_history, :conversation_generation, :bump_generation
      def_delegators :@prompts, :insert_prompt, :activate_prompt, :consume_prompt, :prompt
      def_delegators :@pairing, :pairing_challenges, :insert_pairing_challenge, :approve_pairing
      def_delegators :@outbox, :append_delivery, :claim_delivery, :release_delivery_claim, :mark_delivery_send_started,
                     :mark_delivery, :reconcile_expired_deliveries, :bind_journal_effect, :resolve_delivery
      def_delegators :@pacing, :reserve_delivery_slot, :defer_delivery
      def_delegators :@outbox_reads, :outbox_rows, :outbox_row_for_receipt, :delivered_messages
      def_delegators :@routes, :bind_correspondent, :revoke_binding, :binding, :bind_conversation, :conversation,
                     :bindings, :conversations, :binding_by_conversation

      def initialize(adapter:, checkpoints: nil)
        @adapter = adapter
        @outbox = CommsOutbox.new(adapter:)
        @pacing = CommsPacing.new(adapter:)
        @outbox_reads = CommsOutboxReads.new(adapter:)
        @routes = CommsRoutes.new(adapter:)
        @inbound = CommsInbound.new(adapter:, checkpoints:)
        @polling = CommsPolling.new(adapter:)
        @requests = CommsRequests.new(adapter:, checkpoints:)
        @facts = CommsRequestFacts.new(checkpoints:, outbox: @outbox_reads)
        @status = CommsStatus.new(adapter:, facts: @facts)
        @history = CommsHistory.new(adapter:, checkpoints:)
        @prompts = CommsPrompts.new(adapter:, decisions: CommsDecisionStore.new(adapter:))
        @pairing = CommsPairing.new(adapter:, routes: @routes)
      end

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

      def surfaces
        read('comms.surface.list') do |txn|
          txn.rows('comms.surface.list', <<~SQL).map { |row| SURFACE_COLUMNS.zip(row).to_h }
            SELECT #{SURFACE_COLUMNS.join(', ')} FROM tamoz_comms_surfaces
            ORDER BY surface_id
          SQL
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

      private

      def upsert_surface!(txn, descriptor_wire, now)
        binds = [descriptor_wire.fetch('surface_id'), descriptor_wire.fetch('revision'),
                 descriptor_wire.fetch('definition_digest'), JSON.generate(descriptor_wire),
                 now_ms(now), now_ms(now)]
        txn.execute('comms.surface.deploy.upsert', <<~SQL, binds)
          INSERT INTO tamoz_comms_surfaces (
            surface_id, revision, definition_digest, descriptor_json,
            created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(surface_id) DO UPDATE SET
            revision = excluded.revision,
            definition_digest = excluded.definition_digest,
            descriptor_json = excluded.descriptor_json,
            updated_at_ms = excluded.updated_at_ms
        SQL
      end
    end
  end
end
