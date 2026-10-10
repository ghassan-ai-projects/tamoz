# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # The `channels` section of `tamoz status` (design §14/§16): surfaces, last-poll age, outbox depth, `:unknown`
    # deliveries, and the comms safety counters — all derived from durable rows.
    module CLICommsOps
      include CLICommsShared
      include CLICommsPairing
      include CLICommsRequests

      def comms_status(runtime)
        store = runtime.adapter.bind_comms_store(runtime.checkpoints)
        {
          'surfaces' => store.surfaces.map { |row| surface_status(store, row) },
          'safety_counters' => comms_safety_counters(store)
        }
      end

      private

      def surface_status(store, row)
        descriptor = Tamoz::Comms::SurfaceDescriptor.from_wire(JSON.parse(row.fetch('descriptor_json')))
        poll = store.poll_state(stream_id: descriptor.identity.fetch(:stream_id))
        outbox = store.outbox_counts(surface_id: row.fetch('surface_id'))
        {
          'surface_id' => row.fetch('surface_id'),
          'revision' => row.fetch('revision'),
          'last_poll_at' => poll && ms_to_iso(poll.fetch('updated_at_ms')),
          'outbox_depth' => outbox,
          'unknown_deliveries' => outbox.fetch('unknown', 0)
        }
      end

      # Every counter is a count of durable evidence (design §16):
      # unauthorized admissions are request rows without any active binding;
      # chat grants are membership rows that reached `request` (impossible in
      # v1); the token never reaches a durable record by construction.
      def comms_safety_counters(store)
        audit = store.admission_audit_counts
        {
          'unauthorized_inbound_admissions' => audit.fetch('unauthorized_inbound_admissions'),
          'chat_grants' => audit.fetch('chat_grants'),
          'unknown_deliveries' => store.surfaces.sum do |row|
            store.outbox_counts(surface_id: row.fetch('surface_id')).fetch('unknown', 0)
          end,
          'credential_in_durable_record' => 0
        }
      end
    end
  end
end
