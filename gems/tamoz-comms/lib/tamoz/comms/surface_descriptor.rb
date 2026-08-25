# frozen_string_literal: true

require_relative 'canonical'
require_relative 'errors'
require_relative 'shapes'

module Tamoz
  module Comms
    # Content-addressed operator configuration for one deployed channel
    # (design §6.1). Every field is validated and frozen, the digest binds the
    # deployed contract, and a revision bump is required for ANY change —
    # durable records name the revision they were admitted under, so "who was
    # allowed to do what, when" is answerable without consulting the file.
    #
    # The Telegram API origin is deliberately NOT configurable (design §6.1):
    # a configurable origin is a bot-token exfiltration primitive. Test
    # fixtures are injected as clients, never enabled by production config.
    #
    # The descriptor's fields ARE the value and its validation is the
    # per-field rule set; splitting either would fragment the deployed
    # contract.
    # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # The descriptor is one validated value; the smells below are the
    # per-field rule set and the fifteen facts the digest binds — splitting
    # them would fragment the deployed contract (design §6.1).
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyConstants
    # :reek:TooManyInstanceVariables, :reek:TooManyStatements
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy
    class SurfaceDescriptor
      KINDS = %w[telegram].freeze
      POLL_MODES = %w[long_poll].freeze
      ADMISSION_MODES = %w[disabled allowlist pairing].freeze
      THREADING_MODES = %w[conversation per_message].freeze
      APPROVAL_MODES = %w[none deny_only affirmative].freeze
      MAX_APPROVER_ROLES = 64
      RENDER_FORMATS = %w[plain restricted_html].freeze
      RENDER_OVERFLOWS = %w[truncate].freeze
      CLASSIFICATIONS = %w[restricted].freeze
      DIGEST_DOMAIN = 'tamoz.comms.surface.v1'
      MAX_IDS = 1024

      attr_reader :surface_id, :revision, :kind, :transport, :identity,
                  :admission, :threading, :profile_id, :approvals, :rendering,
                  :limits, :classification, :definition_digest

      def initialize(
        surface_id:, revision:, kind:, transport:, identity:, admission:,
        threading:, profile_id:, approvals:, rendering:, limits:,
        classification:, definition_digest:
      )
        validate!(surface_id:, revision:, kind:, transport:, identity:,
                  admission:, threading:, profile_id:, approvals:, rendering:,
                  limits:, classification:, definition_digest:)
        @surface_id = surface_id
        @revision = revision
        @kind = kind
        @transport = deep_freeze(transport)
        @identity = deep_freeze(identity)
        @admission = deep_freeze(admission)
        @threading = threading
        @profile_id = profile_id
        @approvals = deep_freeze(approvals)
        @rendering = deep_freeze(rendering)
        @limits = deep_freeze(limits)
        @classification = classification
        @definition_digest = definition_digest
        freeze
      end

      # Builds the descriptor and computes its content-address (the digest
      # covers every field, so any change is a new digest and a new revision).
      # @return [SurfaceDescriptor]
      def self.build(surface_id:, revision:, transport:, identity:, admission:, threading:, profile_id:, approvals:,
                     rendering:, limits:, kind: 'telegram', classification: 'restricted')
        digest = Canonical.hexdigest(
          DIGEST_DOMAIN,
          [surface_id, revision, kind, transport, identity, admission,
           threading, profile_id, approvals, rendering, limits, classification]
        )
        new(surface_id:, revision:, kind:, transport:, identity:, admission:,
            threading:, profile_id:, approvals:, rendering:, limits:,
            classification:, definition_digest: digest)
      end

      def wire
        {
          'surface_id' => @surface_id,
          'revision' => @revision,
          'kind' => @kind,
          'transport' => self.class.symbol_keys_to_strings(@transport),
          'identity' => self.class.symbol_keys_to_strings(@identity),
          'admission' => self.class.symbol_keys_to_strings(@admission),
          'threading' => @threading,
          'profile_id' => @profile_id,
          'approvals' => self.class.symbol_keys_to_strings(@approvals),
          'rendering' => self.class.symbol_keys_to_strings(@rendering),
          'limits' => self.class.symbol_keys_to_strings(@limits),
          'classification' => @classification,
          'definition_digest' => @definition_digest
        }
      end

      def self.from_wire(wire)
        new(
          surface_id: wire.fetch('surface_id'),
          revision: wire.fetch('revision'),
          kind: wire.fetch('kind'),
          transport: strings_to_symbol_keys(wire.fetch('transport')),
          identity: strings_to_symbol_keys(wire.fetch('identity')),
          admission: strings_to_symbol_keys(wire.fetch('admission')),
          threading: wire.fetch('threading'),
          profile_id: wire.fetch('profile_id'),
          approvals: strings_to_symbol_keys(wire.fetch('approvals')),
          rendering: strings_to_symbol_keys(wire.fetch('rendering')),
          limits: strings_to_symbol_keys(wire.fetch('limits')),
          classification: wire.fetch('classification'),
          definition_digest: wire.fetch('definition_digest')
        )
      end

      def allowlist? = admission.fetch(:direct) == 'allowlist'

      def pairing? = admission.fetch(:direct) == 'pairing'

      def disabled? = admission.fetch(:direct) == 'disabled'

      class << self
        # Wire-key conversion helpers shared by `wire` and `from_wire`.
        def symbol_keys_to_strings(value)
          value.transform_keys(&:to_s)
        end

        def strings_to_symbol_keys(value)
          value.transform_keys(&:to_sym)
        end
      end

      private

      def validate!(
        surface_id:, revision:, kind:, transport:, identity:, admission:,
        threading:, profile_id:, approvals:, rendering:, limits:,
        classification:, definition_digest:
      )
        unless Shapes.bounded_string?(surface_id, max_bytes: MAX_IDS)
          raise ValidationError, 'surface_id must be a bounded string'
        end
        unless revision.is_a?(Integer) && revision.positive?
          raise ValidationError,
                'revision must be a positive integer'
        end
        raise ValidationError, "kind must be one of #{KINDS.join(', ')}" unless Shapes.member?(kind, KINDS)
        raise ValidationError, "threading must be one of #{THREADING_MODES.join(', ')}" unless Shapes.member?(
          threading, THREADING_MODES
        )
        raise ValidationError, "classification must be one of #{CLASSIFICATIONS.join(', ')}" unless Shapes.member?(
          classification, CLASSIFICATIONS
        )
        unless Shapes.bounded_string?(profile_id, max_bytes: MAX_IDS)
          raise ValidationError, 'profile_id must be a bounded string'
        end
        unless Shapes.hex?(definition_digest.to_s)
          raise ValidationError,
                'definition_digest must be a 64-char hex digest'
        end

        validate_transport!(transport)
        validate_identity!(identity)
        validate_admission!(admission)
        validate_approvals!(approvals)
        validate_rendering!(rendering)
        validate_limits!(limits)
      end

      def validate_transport!(transport)
        raise ValidationError, 'transport mode must be long_poll in v1' unless Shapes.member?(transport.fetch(:mode),
                                                                                              POLL_MODES)
        raise ValidationError, 'transport needs a credential_ref' unless transport.fetch(:credential_ref).is_a?(Hash)
        raise ValidationError, 'poll_timeout_s must be positive' unless Shapes.bounded_integer?(
          transport.fetch(:poll_timeout_s), max: 600
        )
        raise ValidationError, 'batch must be between 1 and 100' unless (1..100).cover?(transport.fetch(:batch))
        cap = transport.fetch(:max_response_bytes)
        return if cap.nil? || Shapes.bounded_integer?(cap, max: 10_000_000)
        raise ValidationError, 'max_response_bytes must be positive'
      end

      def validate_identity!(identity)
        bot_id = identity.fetch(:expected_bot_id)
        return if Shapes.bounded_integer?(bot_id, max: 9_999_999_999_999)

        raise ValidationError, 'expected_bot_id must be a bounded integer'
      end

      def validate_admission!(admission)
        direct = admission.fetch(:direct)
        unless Shapes.member?(direct, ADMISSION_MODES)
          raise ValidationError, "admission must be one of #{ADMISSION_MODES.join(', ')}"
        end
        return unless direct == 'allowlist' && Array(admission[:correspondents]).empty?

        raise ValidationError, 'an empty allowlist is a configuration error, not allow-everything'
      end

      def validate_approvals!(approvals)
        raise ValidationError, "approval mode must be one of #{APPROVAL_MODES.join(', ')}" unless Shapes.member?(
          approvals.fetch(:mode), APPROVAL_MODES
        )
        # T7.1 (PLAN_TAMOZ_STREAM_BUILD T7.1): affirmative approval is a
        # material security-boundary change (PROTOCOL §5.3/§10) — a human's
        # answer travels a trust boundary, so the descriptor must name who may
        # approve. An empty approver list is a configuration error, exactly
        # like an empty admission allowlist: affirmative approval with nobody
        # allowed to approve is not a deployment. The list must be an actual
        # array (a bare string is a configuration error, not a one-element
        # list) and is bounded.
        if approvals.fetch(:mode) == 'affirmative'
          roles = approvals[:approver_roles]
          unless roles.is_a?(Array) && !roles.empty? && roles.length <= MAX_APPROVER_ROLES &&
                 roles.all? { |role| Shapes.bounded_string?(role, max_bytes: MAX_IDS) }
            raise ValidationError,
                  'affirmative approval requires a non-empty approver_roles ' \
                  'array with at most ' \
                  "#{MAX_APPROVER_ROLES} bounded entries"
          end
        end
        return if approvals.fetch(:prompt_ttl_s).is_a?(Integer) && approvals.fetch(:prompt_ttl_s).positive?

        raise ValidationError,
              'prompt_ttl_s must be positive'
      end

      def validate_rendering!(rendering)
        unless Shapes.member?(rendering.fetch(:format), RENDER_FORMATS)
          raise ValidationError, "render format must be one of #{RENDER_FORMATS.join(', ')}"
        end
        unless rendering.fetch(:max_parts).is_a?(Integer) && rendering.fetch(:max_parts).positive?
          raise ValidationError, 'max_parts must be positive'
        end
        unless rendering.fetch(:part_characters).is_a?(Integer) && rendering.fetch(:part_characters).positive?
          raise ValidationError, 'part_characters must be positive'
        end
        raise ValidationError, 'overflow must be truncate in v1' unless Shapes.member?(rendering.fetch(:overflow),
                                                                                       RENDER_OVERFLOWS)
      end

      def validate_limits!(limits)
        %i[max_inbound_bytes max_open_requests max_denial_prompts_per_request
           outbox_capacity control_capacity].each do |key|
          unless limits.fetch(key).is_a?(Integer) && limits.fetch(key).positive?
            raise ValidationError, "#{key} must be positive"
          end
        end
        %i[per_chat_messages_per_s global_messages_per_s].each do |key|
          rate = limits.fetch(key)
          raise ValidationError, "#{key} must be a positive number" unless rate.is_a?(Numeric) && rate.positive?
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, entry), memo| memo[key] = deep_freeze(entry) }.freeze
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        else
          value.freeze
        end
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
