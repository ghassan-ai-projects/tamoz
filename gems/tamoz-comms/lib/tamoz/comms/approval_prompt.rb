# frozen_string_literal: true

require 'securerandom'
require 'time'

require_relative 'canonical'
require_relative 'errors'
require_relative 'interrupt_digest'
require_relative 'authority_evidence'
require_relative 'shapes'

module Tamoz
  module Comms
    # A single-use, expiring approval prompt for one exact callback binding
    # (design §9, ADR-043). The gateway stores only the domain-separated digest
    # of the 128-bit reference; the prompt is INACTIVE until a durable send
    # receipt activates it, and consumption is atomic against every stored
    # binding. A replay, an expiry, or a swapped binding never resolves.
    #
    # The prompt's fifteen fields ARE the value and its validation is the
    # per-field rule set; splitting either would fragment the row the store
    # persists.
    # rubocop:disable Metrics/ParameterLists
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:NilCheck, :reek:DataClump
    class ApprovalPrompt
      STATUSES = %w[inactive active consumed].freeze
      REFERENCE_DOMAIN = 'tamoz.comms.prompt_ref.v1'
      MAX_ID_BYTES = 256
      TIME_FIELDS = %i[created_at activated_at consumed_at expires_at].freeze
      private_constant :TIME_FIELDS

      attr_reader :reference_digest, :surface_id, :surface_revision, :thread_id,
                  :occurrence_id, :interrupt_digest, :correspondent_id,
                  :conversation_id, :prompt_receipt, :required_evidence, :status,
                  :created_at, :activated_at, :consumed_at, :expires_at

      def initialize(
        reference_digest:, surface_id:, surface_revision:, thread_id:,
        occurrence_id:, interrupt_digest:, correspondent_id:, conversation_id:,
        created_at:, expires_at:, prompt_receipt: nil, status: 'inactive',
        required_evidence:, activated_at: nil, consumed_at: nil
      )
        fields = {
          reference_digest:, surface_id:, surface_revision:, thread_id:, occurrence_id:, interrupt_digest:,
          correspondent_id:, conversation_id:, prompt_receipt:, required_evidence:, status:,
          created_at:, activated_at:, consumed_at:, expires_at:
        }
        validate!(fields)
        fields.each { |name, value| instance_variable_set(:"@#{name}", stored(name, value)) }
        freeze
      end

      # Builds the prompt from a fresh 128-bit reference; only its digest is
      # ever stored. The plaintext reference lives in memory for exactly one
      # control-send attempt (design §7). The requirement is pinned at build
      # time from the caller-supplied symbol — the `required_evidence` the
      # engine's Decision carries (INV-C) — in the same value as the
      # interrupt digest, and the surface binding is captured so the callback
      # comparison can verify it (contract §7.1). A symbol outside the closed
      # lattice raises here; it is never coerced to a weaker one.
      def self.build(
        surface_id:, surface_revision:, thread_id:, occurrence_id:, interrupts:,
        required_evidence:, correspondent_id:, conversation_id:, prompt_ttl_s:,
        created_at: Time.now.utc
      )
        reference = SecureRandom.random_bytes(16).unpack1('H*')
        digest = Canonical.hexdigest(REFERENCE_DOMAIN, reference)
        prompt = new(
          reference_digest: digest, surface_id:, surface_revision:,
          thread_id:, occurrence_id:, interrupt_digest: InterruptDigest.of(interrupts),
          correspondent_id:, conversation_id:,
          required_evidence: required_evidence.to_s,
          created_at:, expires_at: created_at + prompt_ttl_s
        )
        [reference, prompt]
      end

      def active? = status == 'active'

      def consumed? = status == 'consumed'

      def expired?(now) = now >= @expires_at

      def wire
        {
          'reference_digest' => @reference_digest,
          'surface_id' => @surface_id,
          'surface_revision' => @surface_revision,
          'thread_id' => @thread_id,
          'occurrence_id' => @occurrence_id,
          'interrupt_digest' => @interrupt_digest,
          'required_evidence' => @required_evidence,
          'correspondent_id' => @correspondent_id,
          'conversation_id' => @conversation_id,
          'prompt_receipt' => @prompt_receipt,
          'status' => @status,
          'created_at' => @created_at.iso8601(6),
          'activated_at' => @activated_at&.iso8601(6),
          'consumed_at' => @consumed_at&.iso8601(6),
          'expires_at' => @expires_at.iso8601(6)
        }
      end

      def self.from_wire(wire)
        new(
          reference_digest: wire.fetch('reference_digest'),
          surface_id: wire['surface_id'],
          surface_revision: wire['surface_revision'],
          thread_id: wire.fetch('thread_id'),
          occurrence_id: wire.fetch('occurrence_id'),
          interrupt_digest: wire.fetch('interrupt_digest'),
          correspondent_id: wire.fetch('correspondent_id'),
          conversation_id: wire.fetch('conversation_id'),
          prompt_receipt: wire['prompt_receipt'],
          required_evidence: wire.fetch('required_evidence'),
          status: wire.fetch('status'),
          created_at: Time.parse(wire.fetch('created_at')),
          activated_at: wire_time(wire, 'activated_at'),
          consumed_at: wire_time(wire, 'consumed_at'),
          expires_at: Time.parse(wire.fetch('expires_at'))
        )
      end

      def self.wire_time(wire, key)
        value = wire[key]
        value && Time.parse(value)
      end

      private

      def stored(name, value)
        TIME_FIELDS.include?(name) ? value&.utc : value
      end

      def validate!(fields)
        validate_identity!(fields)
        validate_lifecycle!(fields)
      end

      def validate_identity!(fields)
        unless Shapes.hex?(fields.fetch(:reference_digest), bits: 256)
          raise ValidationError, 'reference_digest must be a 64-char hex digest'
        end

        validate_identity_strings!(fields.values_at(:surface_id, :thread_id, :occurrence_id, :correspondent_id,
                                                    :conversation_id))
        unless Shapes.hex?(fields.fetch(:interrupt_digest))
          raise ValidationError, 'interrupt_digest must be a 64-char hex digest'
        end

        validate_surface_revision!(fields.fetch(:surface_revision))
        validate_required_evidence!(fields.fetch(:required_evidence))
        receipt = fields.fetch(:prompt_receipt)
        return if receipt.nil? || Shapes.bounded_string?(receipt, max_bytes: MAX_ID_BYTES)

        raise ValidationError, 'prompt_receipt must be a bounded string'
      end

      def validate_identity_strings!(values)
        values.each do |value|
          next if value.nil? || Shapes.bounded_string?(value, max_bytes: MAX_ID_BYTES)

          raise ValidationError, 'prompt identity fields must be bounded strings'
        end
      end

      def validate_surface_revision!(surface_revision)
        return if surface_revision.nil? || (surface_revision.is_a?(Integer) && surface_revision.positive?)

        raise ValidationError, 'surface_revision must be a positive integer'
      end

      # A non-lattice requirement is rejected, never coerced to a weaker one;
      # `AuthorityEvidence.from`'s ValidationError is the per-field rule.
      def validate_required_evidence!(required_evidence)
        AuthorityEvidence.from(required_evidence)
      end

      def validate_lifecycle!(fields)
        status = fields.fetch(:status)
        raise ValidationError, "status must be one of #{STATUSES.join(', ')}" unless Shapes.member?(status, STATUSES)

        validate_window!(fields.fetch(:created_at), fields.fetch(:expires_at))
        if status == 'consumed' && fields.fetch(:consumed_at).nil?
          raise ValidationError, 'a consumed prompt needs consumed_at'
        end
        return unless status == 'active' && fields.fetch(:activated_at).nil?

        raise ValidationError, 'an active prompt needs activated_at'
      end

      def validate_window!(created_at, expires_at)
        [created_at, expires_at].each do |time|
          raise ValidationError, 'prompt times must be Time values' unless time.is_a?(Time)
        end
        raise ValidationError, 'expires_at must follow created_at' unless expires_at > created_at
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
