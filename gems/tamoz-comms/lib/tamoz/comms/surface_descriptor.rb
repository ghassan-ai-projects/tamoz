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
    # The descriptor's fields ARE the value and its validation is the
    # per-field rule set; splitting either would fragment the deployed
    # contract.
    # rubocop:disable Metrics/ParameterLists
    # The descriptor is one validated value; the smells below are the
    # per-field rule set and the fifteen facts the digest binds — splitting
    # them would fragment the deployed contract (design §6.1).
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyConstants
    # :reek:TooManyInstanceVariables, :reek:TooManyStatements
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy
    class SurfaceDescriptor
      KIND_NAME = /\A[a-z][a-z0-9_]{1,31}\z/
      RESERVED_KINDS = %w[os cli].freeze
      MAX_SETTINGS_BYTES = 4096
      STREAM = /\A[a-z][a-z0-9_]{1,31}:[!-~]{1,200}\z/
      ADMISSION_MODES = %w[disabled allowlist pairing].freeze
      THREADING_MODES = %w[conversation per_message].freeze
      APPROVAL_MODES = %w[none deny_only affirmative].freeze
      MAX_APPROVER_ROLES = 64
      RENDER_FORMATS = %w[plain restricted_html].freeze
      RENDER_OVERFLOWS = %w[truncate].freeze
      CLASSIFICATIONS = %w[restricted].freeze
      DIGEST_DOMAIN = 'tamoz.comms.surface.v1'
      MAX_IDS = 1024
      STRUCTURED_FIELDS = %i[transport identity settings admission approvals rendering limits].freeze
      private_constant :STRUCTURED_FIELDS

      attr_reader :surface_id, :revision, :kind, :transport, :identity, :settings,
                  :admission, :threading, :profile_id, :profile_digest, :approvals, :rendering,
                  :limits, :classification, :definition_digest

      def initialize(
        surface_id:, revision:, kind:, transport:, identity:, settings:, admission:,
        threading:, profile_id:, approvals:, rendering:, limits:,
        classification:, definition_digest:, profile_digest: nil
      )
        fields = {
          surface_id:, revision:, kind:, transport:, identity:, settings:, admission:, threading:, profile_id:,
          profile_digest:, approvals:, rendering:, limits:, classification:, definition_digest:
        }
        validate!(fields)
        fields.each { |name, value| instance_variable_set(:"@#{name}", stored(name, value)) }
        freeze
      end

      # Builds the descriptor and computes its content-address (the digest
      # covers every field, so any change is a new digest and a new revision).
      # `profile_digest` is the authority the deployed surface pins; a surface
      # deployed without one cannot execute a bound thread (the worker refuses
      # an unpinned binding) — see `Gateway::AdmissionBinding`.
      # @return [SurfaceDescriptor]
      def self.build(surface_id:, revision:, kind:, transport:, identity:, admission:, threading:, profile_id:,
                     approvals:, rendering:, limits:, settings: {}, classification: 'restricted', profile_digest: nil)
        digest = Canonical.hexdigest(
          DIGEST_DOMAIN,
          [surface_id, revision, kind, transport, identity, settings, admission,
           threading, profile_id, profile_digest, approvals, rendering, limits, classification]
        )
        new(surface_id:, revision:, kind:, transport:, identity:, settings:, admission:,
            threading:, profile_id:, profile_digest:, approvals:, rendering:, limits:,
            classification:, definition_digest: digest)
      end

      def wire
        {
          'surface_id' => @surface_id,
          'revision' => @revision,
          'kind' => @kind,
          'transport' => self.class.symbol_keys_to_strings(@transport),
          'identity' => self.class.symbol_keys_to_strings(@identity),
          'settings' => self.class.symbol_keys_to_strings(@settings),
          'admission' => self.class.symbol_keys_to_strings(@admission),
          'threading' => @threading,
          'profile_id' => @profile_id,
          'profile_digest' => @profile_digest,
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
          transport: symbolized_field(wire, 'transport'),
          identity: symbolized_field(wire, 'identity'),
          settings: symbolized_field(wire, 'settings'),
          admission: symbolized_field(wire, 'admission'),
          threading: wire.fetch('threading'),
          profile_id: wire.fetch('profile_id'),
          profile_digest: wire['profile_digest'],
          approvals: symbolized_field(wire, 'approvals'),
          rendering: symbolized_field(wire, 'rendering'),
          limits: symbolized_field(wire, 'limits'),
          classification: wire.fetch('classification'),
          definition_digest: wire.fetch('definition_digest')
        )
      end

      def allowlist? = admission.fetch(:direct) == 'allowlist'

      def pairing? = admission.fetch(:direct) == 'pairing'

      def disabled? = admission.fetch(:direct) == 'disabled'

      def speech? = rendering.fetch(:speech, false)

      def self.valid_kind?(kind) = kind.is_a?(String) && kind.match?(KIND_NAME) && !RESERVED_KINDS.include?(kind)

      class << self
        # Wire-key conversion helpers shared by `wire` and `from_wire`.
        def symbol_keys_to_strings(value)
          value.transform_keys(&:to_s)
        end

        def strings_to_symbol_keys(value)
          value.transform_keys(&:to_sym)
        end
      end

      def self.symbolized_field(wire, name)
        strings_to_symbol_keys(wire.fetch(name))
      end
      private_class_method :symbolized_field

      private

      def stored(name, value)
        STRUCTURED_FIELDS.include?(name) ? deep_freeze(value) : value
      end

      def validate!(fields)
        validate_classification!(fields)
        validate_references!(fields)
        validate_transport!(fields.fetch(:transport))
        validate_settings!(fields.fetch(:settings))
        validate_identity!(fields.fetch(:identity), fields.fetch(:kind))
        validate_admission!(fields.fetch(:admission))
        validate_approvals!(fields.fetch(:approvals))
        validate_rendering!(fields.fetch(:rendering))
        validate_limits!(fields.fetch(:limits))
      end

      def validate_classification!(fields)
        Shapes.require_string!(fields.fetch(:surface_id), 'surface_id', max_bytes: MAX_IDS)
        Shapes.require_positive!(fields.fetch(:revision), 'revision')
        raise ValidationError, 'kind must be a lowercase name that is not os or cli' unless
          self.class.valid_kind?(fields.fetch(:kind))
        Shapes.require_member!(fields.fetch(:threading), THREADING_MODES, 'threading')
        Shapes.require_member!(fields.fetch(:classification), CLASSIFICATIONS, 'classification')
      end

      def validate_references!(fields)
        Shapes.require_string!(fields.fetch(:profile_id), 'profile_id', max_bytes: MAX_IDS)
        profile_digest = fields.fetch(:profile_digest)
        unless profile_digest.nil? || profile_digest.to_s.start_with?('sha256:')
          raise ValidationError, 'profile_digest must be a sha256: digest'
        end
        return if Shapes.hex?(fields.fetch(:definition_digest).to_s)

        raise ValidationError, 'definition_digest must be a 64-char hex digest'
      end

      def validate_transport!(transport)
        raise ValidationError, 'transport needs a credential_ref' unless transport.fetch(:credential_ref).is_a?(Hash)
        raise ValidationError, 'poll_timeout_s must be positive' unless Shapes.bounded_integer?(
          transport.fetch(:poll_timeout_s), max: 600
        )
        raise ValidationError, 'batch must be between 1 and 100' unless (1..100).cover?(transport.fetch(:batch))
        cap = transport.fetch(:max_response_bytes)
        return if cap.nil? || Shapes.bounded_integer?(cap, max: 10_000_000)
        raise ValidationError, 'max_response_bytes must be positive'
      end

      def validate_settings!(settings)
        raise ValidationError, 'settings must be a mapping' unless settings.is_a?(Hash)
        return if Canonical.canonical_bytes(settings).bytesize <= MAX_SETTINGS_BYTES

        raise ValidationError, "settings must be at most #{MAX_SETTINGS_BYTES} bytes"
      end

      # The update stream the surface consumes is named for its kind, so two kinds can never share a lease.
      def validate_identity!(identity, kind)
        stream = identity[:stream_id]
        return if identity.keys == [:stream_id] && stream.is_a?(String) && stream.match?(STREAM) &&
                  stream.start_with?("#{kind}:")

        raise ValidationError, 'identity is one stream_id, "<kind>:<name>"'
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
        validate_approver_roles!(approvals[:approver_roles]) if approvals.fetch(:mode) == 'affirmative'
        return if approvals.fetch(:prompt_ttl_s).is_a?(Integer) && approvals.fetch(:prompt_ttl_s).positive?

        raise ValidationError, 'prompt_ttl_s must be positive'
      end

      def validate_approver_roles!(roles)
        return if roles.is_a?(Array) && !roles.empty? && roles.length <= MAX_APPROVER_ROLES &&
                  roles.all? { |role| Shapes.bounded_string?(role, max_bytes: MAX_IDS) }

        raise ValidationError,
              "affirmative approval requires a non-empty approver_roles array with at most #{MAX_APPROVER_ROLES} " \
              'bounded entries'
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
        validate_speech!(rendering)
      end

      def validate_speech!(rendering)
        speech = rendering.fetch(:speech, false)
        raise ValidationError, 'speech must be true or false' unless [true, false].include?(speech)
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
# rubocop:enable Metrics/ParameterLists
