# frozen_string_literal: true

module Tamoz
  module Agent
    # One channel's config entry as the descriptor it deploys: defaults fill what the operator may omit.
    module SurfaceConfig
      DEFAULTS = {
        'admission' => { 'direct' => 'disabled' },
        'approvals' => { 'mode' => 'none', 'prompt_ttl_s' => 900 },
        'rendering' => { 'format' => 'plain', 'max_parts' => 5, 'part_characters' => 3500, 'overflow' => 'truncate',
                         'speech' => false },
        'limits' => { 'max_inbound_bytes' => 8192, 'max_open_requests' => 50, 'max_denial_prompts_per_request' => 4,
                      'outbox_capacity' => 500, 'control_capacity' => 50, 'per_chat_messages_per_s' => 1.0,
                      'global_messages_per_s' => 25.0 }
      }.freeze

      module_function

      def descriptor(surface_id, entry, profile_digest:)
        sections = DEFAULTS.to_h { |name, defaults| [name.to_sym, symbolize(defaults.merge(entry.fetch(name, {})))] }
        Tamoz::Comms::SurfaceDescriptor.build(
          surface_id:, kind: entry.fetch('kind'), revision: entry.fetch('revision'), transport: transport(entry),
          identity: { stream_id: entry.fetch('stream_id') }, settings: symbolize(entry.fetch('settings', {})),
          threading: entry.fetch('threading', 'conversation'), profile_id: entry.fetch('profile'), profile_digest:,
          **sections
        )
      end

      def transport(entry)
        given = entry['transport'] || {}
        { credential_ref: symbolize(entry.fetch('credential_ref')), poll_timeout_s: given['poll_timeout_s'] || 30,
          batch: given['batch'] || 50, max_response_bytes: given['max_response_bytes'] }
      end

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, entry| [key.to_sym, symbolize(entry)] }
        when Array then value.map { |entry| symbolize(entry) }
        else value
        end
      end
    end
  end
end
