# frozen_string_literal: true

require_relative 'canonical'
require_relative 'errors'
require_relative 'shapes'
require_relative 'surface_rules'

module Tamoz
  module Comms
    SurfaceDescriptor = Data.define(:surface_id, :revision, :kind, :transport, :identity, :settings,
                                    :admission, :threading, :profile_id, :profile_digest, :approvals,
                                    :rendering, :limits, :classification, :definition_digest)

    # Content-addressed operator configuration for one deployed channel
    # (design §6.1). Every field is validated and frozen, the digest binds the
    # deployed contract, and a revision bump is required for ANY change —
    # durable records name the revision they were admitted under, so "who was
    # allowed to do what, when" is answerable without consulting the file.
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

      def initialize(profile_digest: nil, **fields)
        super(profile_digest:, **fields.to_h { |name, value| [name, stored(name, value)] })
        SurfaceRules.validate!(self)
      end

      # Builds the descriptor and computes its content-address (the digest
      # covers every field, so any change is a new digest and a new revision).
      # `profile_digest` is the authority the deployed surface pins; a surface
      # deployed without one cannot execute a bound thread (the worker refuses
      # an unpinned binding) — see `Gateway::AdmissionBinding`.
      def self.build(settings: {}, classification: 'restricted', profile_digest: nil, **fields)
        fields = fields.merge(settings:, classification:, profile_digest:)
        digest = Canonical.hexdigest(DIGEST_DOMAIN, (members - [:definition_digest]).map { |name| fields.fetch(name) })
        new(**fields, definition_digest: digest)
      end

      def wire
        to_h.to_h { |name, value| [name.to_s, STRUCTURED_FIELDS.include?(name) ? value.transform_keys(&:to_s) : value] }
      end

      def self.from_wire(wire)
        new(**members.to_h do |name|
          value = name == :profile_digest ? wire[name.to_s] : wire.fetch(name.to_s)
          [name, STRUCTURED_FIELDS.include?(name) ? value.transform_keys(&:to_sym) : value]
        end)
      end

      def allowlist? = admission.fetch(:direct) == 'allowlist'

      def pairing? = admission.fetch(:direct) == 'pairing'

      def disabled? = admission.fetch(:direct) == 'disabled'

      def speech? = rendering.fetch(:speech, false)

      def self.valid_kind?(kind) = kind.is_a?(String) && kind.match?(KIND_NAME) && !RESERVED_KINDS.include?(kind)

      def self.frozen_copy(value)
        case value
        when Hash then value.to_h { |key, entry| [key, frozen_copy(entry)] }.freeze
        when Array then value.map { |entry| frozen_copy(entry) }.freeze
        else value.freeze
        end
      end

      private

      def stored(name, value) = STRUCTURED_FIELDS.include?(name) ? self.class.frozen_copy(value) : value
    end
  end
end
