# frozen_string_literal: true

require_relative 'canonical'
require_relative 'errors'
require_relative 'shapes'

module Tamoz
  module Comms
    # The rules a SurfaceDescriptor must satisfy, one method per field group.
    # :reek:MissingSafeMethod, :reek:FeatureEnvy, :reek:DuplicateMethodCall
    module SurfaceRules
      module_function

      def validate!(descriptor)
        validate_classification!(descriptor)
        validate_references!(descriptor)
        validate_transport!(descriptor.transport)
        validate_settings!(descriptor.settings)
        validate_identity!(descriptor.identity, descriptor.kind)
        validate_admission!(descriptor.admission)
        validate_approvals!(descriptor.approvals)
        validate_rendering!(descriptor.rendering)
        validate_limits!(descriptor.limits)
      end

      def validate_classification!(descriptor)
        Shapes.require_string!(descriptor.surface_id, 'surface_id', max_bytes: SurfaceDescriptor::MAX_IDS)
        Shapes.require_positive!(descriptor.revision, 'revision')
        raise ValidationError, 'kind must be a lowercase name that is not os or cli' unless
          SurfaceDescriptor.valid_kind?(descriptor.kind)

        Shapes.require_member!(descriptor.threading, SurfaceDescriptor::THREADING_MODES, 'threading')
        Shapes.require_member!(descriptor.classification, SurfaceDescriptor::CLASSIFICATIONS, 'classification')
      end

      def validate_references!(descriptor)
        Shapes.require_string!(descriptor.profile_id, 'profile_id', max_bytes: SurfaceDescriptor::MAX_IDS)
        profile_digest = descriptor.profile_digest
        unless profile_digest.nil? || profile_digest.to_s.start_with?('sha256:')
          raise ValidationError, 'profile_digest must be a sha256: digest'
        end
        return if Shapes.hex?(descriptor.definition_digest.to_s)

        raise ValidationError, 'definition_digest must be a 64-char hex digest'
      end

      def validate_transport!(transport)
        raise ValidationError, 'transport needs a credential_ref' unless transport.fetch(:credential_ref).is_a?(Hash)
        raise ValidationError, 'poll_timeout_s must be positive' unless
          Shapes.bounded_integer?(transport.fetch(:poll_timeout_s), max: 600)
        raise ValidationError, 'batch must be between 1 and 100' unless (1..100).cover?(transport.fetch(:batch))

        cap = transport.fetch(:max_response_bytes)
        return if cap.nil? || Shapes.bounded_integer?(cap, max: 10_000_000)

        raise ValidationError, 'max_response_bytes must be positive'
      end

      def validate_settings!(settings)
        raise ValidationError, 'settings must be a mapping' unless settings.is_a?(Hash)
        return if Canonical.canonical_bytes(settings).bytesize <= SurfaceDescriptor::MAX_SETTINGS_BYTES

        raise ValidationError, "settings must be at most #{SurfaceDescriptor::MAX_SETTINGS_BYTES} bytes"
      end

      # The update stream the surface consumes is named for its kind, so two kinds can never share a lease.
      def validate_identity!(identity, kind)
        stream = identity[:stream_id]
        return if identity.keys == [:stream_id] && stream.is_a?(String) &&
                  stream.match?(SurfaceDescriptor::STREAM) && stream.start_with?("#{kind}:")

        raise ValidationError, 'identity is one stream_id, "<kind>:<name>"'
      end

      def validate_admission!(admission)
        direct = admission.fetch(:direct)
        unless Shapes.member?(direct, SurfaceDescriptor::ADMISSION_MODES)
          raise ValidationError, "admission must be one of #{SurfaceDescriptor::ADMISSION_MODES.join(', ')}"
        end
        return unless direct == 'allowlist' && Array(admission[:correspondents]).empty?

        raise ValidationError, 'an empty allowlist is a configuration error, not allow-everything'
      end

      # Affirmative approval with nobody allowed to approve is not a deployment, like an empty allowlist.
      def validate_approvals!(approvals)
        mode = approvals.fetch(:mode)
        unless Shapes.member?(mode, SurfaceDescriptor::APPROVAL_MODES)
          raise ValidationError, "approval mode must be one of #{SurfaceDescriptor::APPROVAL_MODES.join(', ')}"
        end

        validate_approver_roles!(approvals[:approver_roles]) if mode == 'affirmative'
        positive!(approvals.fetch(:prompt_ttl_s), 'prompt_ttl_s')
      end

      def validate_approver_roles!(roles)
        return if roles.is_a?(Array) && !roles.empty? && roles.length <= SurfaceDescriptor::MAX_APPROVER_ROLES &&
                  roles.all? { |role| Shapes.bounded_string?(role, max_bytes: SurfaceDescriptor::MAX_IDS) }

        raise ValidationError, 'affirmative approval requires a non-empty approver_roles array with at most ' \
                               "#{SurfaceDescriptor::MAX_APPROVER_ROLES} bounded entries"
      end

      def validate_rendering!(rendering)
        unless Shapes.member?(rendering.fetch(:format), SurfaceDescriptor::RENDER_FORMATS)
          raise ValidationError, "render format must be one of #{SurfaceDescriptor::RENDER_FORMATS.join(', ')}"
        end

        positive!(rendering.fetch(:max_parts), 'max_parts')
        positive!(rendering.fetch(:part_characters), 'part_characters')
        raise ValidationError, 'overflow must be truncate in v1' unless
          Shapes.member?(rendering.fetch(:overflow), SurfaceDescriptor::RENDER_OVERFLOWS)
        raise ValidationError, 'speech must be true or false' unless [true,
                                                                      false].include?(rendering.fetch(:speech, false))
      end

      def validate_limits!(limits)
        %i[max_inbound_bytes max_open_requests max_denial_prompts_per_request outbox_capacity control_capacity]
          .each { |key| positive!(limits.fetch(key), key) }
        %i[per_chat_messages_per_s global_messages_per_s].each do |key|
          rate = limits.fetch(key)
          raise ValidationError, "#{key} must be a positive number" unless rate.is_a?(Numeric) && rate.positive?
        end
      end

      def positive!(value, name)
        raise ValidationError, "#{name} must be positive" unless value.is_a?(Integer) && value.positive?
      end
    end
  end
end
