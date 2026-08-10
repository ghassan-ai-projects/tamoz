# frozen_string_literal: true

require 'time'

require_relative 'canonical'
require_relative 'errors'
require_relative 'interrupt_digest'

module Tamoz
  module Comms
    # Immutable, exact operator decision about one paused occurrence (design §9).
    #
    # A decision answers ONE interrupt set: it carries the canonical digest of
    # the interrupts the turn was paused on, so a decision recorded for one
    # question can never be consumed by a later pause in the same occurrence.
    # The id is derived — never random — so the CLI writing the same decision
    # twice is idempotent, and the worker's resume request id is derived from
    # the decision id, so a crash between enqueue and consumption repeats the
    # same inbox request instead of duplicating it.
    #
    # The durable wire form is a string-keyed hash (`wire` / `from_wire`); the
    # SQLite decision store implements its contract over that form without
    # referencing this constant (dependency rule 9).
    #
    # The class-level structure is the design §9 contract itself: fifteen
    # fields, seven vocabulary constants, bang validators, and one row per
    # record. Splitting them would fragment the record the store persists as a
    # single wire hash.
    # :reek:TooManyConstants, :reek:TooManyInstanceVariables, :reek:TooManyMethods
    # :reek:MissingSafeMethod -- every `validate_*!` raises by construction;
    #   a "safe" variant would be a lie.
    # :reek:LongParameterList -- the fifteen fields ARE the record (see above).
    # :reek:FeatureEnvy -- `==` and the field validators necessarily read the
    #   other value/wire being compared.
    # :reek:ControlParameter -- `interrupt_digest:` on `build` lets the
    #   gateway bind the prompt's pre-computed digest to the deny decision it
    #   records for the same interrupt set (ADR-043); deriving it again from
    #   an empty interrupt list would forge a different question.
    class DecisionRecord
      DIRECTIONS = %w[approve deny].freeze
      ACTOR_KINDS = %w[os_user telegram_user].freeze
      SOURCES = %w[cli telegram].freeze
      STATUSES = %w[pending claimed consumed].freeze
      DEFAULT_TTL_S = 900
      ID_DOMAIN = 'tamoz.comms.decision.v1'
      WIRE_TIME = '%Y-%m-%dT%H:%M:%S.%6NZ'

      attr_reader :decision_id, :thread_id, :occurrence_id, :interrupt_digest,
                  :direction, :actor_kind, :actor_id, :source,
                  :decided_at, :expires_at, :status,
                  :claim_owner, :claim_fence, :claim_expires_at, :consumed_at

      # The decision's fifteen fields ARE the value: design §9 binds every one
      # of them into the record the store persists as one row, so splitting
      # them into sub-values would fragment the contract rather than simplify
      # it.
      # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
      def initialize(
        decision_id:, thread_id:, occurrence_id:, interrupt_digest:,
        direction:, actor_kind:, actor_id:, source:,
        decided_at:, expires_at:, status:,
        claim_owner: nil, claim_fence: nil, claim_expires_at: nil, consumed_at: nil
      )
        validate_identity!(thread_id:, occurrence_id:, interrupt_digest:)
        validate_direction!(direction)
        validate_actor!(actor_kind:, actor_id:, source:)
        validate_times!(decided_at:, expires_at:)
        validate_status!(status)
        validate_claim!(status:, claim_owner:, claim_fence:, claim_expires_at:)
        validate_consumption!(status:, consumed_at:)
        validate_id!(decision_id:)
        @decision_id = decision_id
        @thread_id = thread_id
        @occurrence_id = occurrence_id
        @interrupt_digest = interrupt_digest
        @direction = direction
        @actor_kind = actor_kind
        @actor_id = actor_id
        @source = source
        @decided_at = decided_at.utc
        @expires_at = expires_at.utc
        @status = status
        @claim_owner = claim_owner
        @claim_fence = claim_fence
        @claim_expires_at = claim_expires_at&.utc
        @consumed_at = consumed_at&.utc
        freeze
      end
      # rubocop:enable Metrics/ParameterLists, Metrics/MethodLength

      # Builds a pending decision from a live interrupt set, deriving the
      # interrupt digest and the decision id. `decided_at` defaults to now and
      # is part of the id: a later re-decision of the SAME question is a NEW
      # decision (single-use consumption), never a duplicate of a consumed one.
      # @return [DecisionRecord]
      # rubocop:disable Metrics/ParameterLists -- the same fifteen-field value
      # contract as initialize: every bound fact is part of the record.
      def self.build(
        thread_id:, occurrence_id:, interrupts:, direction:,
        actor_kind:, actor_id:, source:, decided_at: Time.now.utc, ttl_s: DEFAULT_TTL_S,
        interrupt_digest: nil
      )
        digest = interrupt_digest || InterruptDigest.of(interrupts)
        direction_text = direction.to_s
        decided = decided_at.utc
        expires = decided + ttl_s
        new(
          decision_id: decision_id_for(
            thread_id:, occurrence_id:, digest:,
            direction: direction_text, actor_kind:, actor_id:, source:, decided_at: decided
          ),
          thread_id:, occurrence_id:, interrupt_digest: digest,
          direction: direction_text, actor_kind:, actor_id:, source:,
          decided_at: decided, expires_at: expires, status: 'pending'
        )
      end
      # rubocop:enable Metrics/ParameterLists

      # Same fifteen-field value contract as initialize: every bound fact is
      # part of the derived id.
      # rubocop:disable Metrics/ParameterLists
      def self.decision_id_for(
        thread_id:, occurrence_id:, digest:, direction:,
        actor_kind:, actor_id:, source:, decided_at:
      )
        raise ValidationError, "direction must be one of #{DIRECTIONS.join(', ')}" unless DIRECTIONS.include?(direction)

        Canonical.hexdigest(
          ID_DOMAIN,
          [thread_id, occurrence_id, digest, direction, actor_kind, actor_id, source, decided_at]
        )
      end
      # rubocop:enable Metrics/ParameterLists

      def granted? = direction == 'approve'
      def denied? = direction == 'deny'

      def ==(other)
        other.is_a?(DecisionRecord) && wire == other.wire
      end
      alias eql? ==

      def hash = wire.hash

      # The inbox request id under which the worker resumes the occurrence.
      # Derived, so a crash after enqueue repeats the same request and the
      # inbox deduplicates (invariant 23).
      def resume_request_id = "decision-#{decision_id}"

      def expired?(now) = now >= @expires_at

      def pending? = status == 'pending'

      def claimed? = status == 'claimed'

      def consumed? = status == 'consumed'

      # @return [Hash] the durable string-keyed wire form.
      def wire
        {
          'decision_id' => @decision_id,
          'thread_id' => @thread_id,
          'occurrence_id' => @occurrence_id,
          'interrupt_digest' => @interrupt_digest,
          'direction' => @direction,
          'actor_kind' => @actor_kind,
          'actor_id' => @actor_id,
          'source' => @source,
          'decided_at' => @decided_at.strftime(WIRE_TIME),
          'expires_at' => @expires_at.strftime(WIRE_TIME),
          'status' => @status,
          'claim_owner' => @claim_owner,
          'claim_fence' => @claim_fence,
          'claim_expires_at' => @claim_expires_at&.strftime(WIRE_TIME),
          'consumed_at' => @consumed_at&.strftime(WIRE_TIME)
        }
      end

      # @param wire [Hash] a hash produced by `wire` (or an equivalent writer).
      # @return [DecisionRecord]
      def self.from_wire(wire)
        new(
          decision_id: wire.fetch('decision_id'),
          thread_id: wire.fetch('thread_id'),
          occurrence_id: wire.fetch('occurrence_id'),
          interrupt_digest: wire.fetch('interrupt_digest'),
          direction: wire.fetch('direction'),
          actor_kind: wire.fetch('actor_kind'),
          actor_id: wire.fetch('actor_id'),
          source: wire.fetch('source'),
          decided_at: Time.parse(wire.fetch('decided_at')),
          expires_at: Time.parse(wire.fetch('expires_at')),
          status: wire.fetch('status'),
          claim_owner: wire['claim_owner'],
          claim_fence: wire['claim_fence'],
          claim_expires_at: wire_time(wire, 'claim_expires_at'),
          consumed_at: wire_time(wire, 'consumed_at')
        )
      end

      def self.wire_time(wire, key)
        value = wire[key]
        value && Time.parse(value)
      end

      private

      def validate_identity!(thread_id:, occurrence_id:, interrupt_digest:)
        unless bounded_string?(thread_id) && bounded_string?(occurrence_id)
          raise ValidationError, 'decision identity fields must be bounded strings'
        end

        validate_hex!(interrupt_digest, 'interrupt_digest')
      end

      # A pure field-shape predicate shared by the identity/actor validators;
      # the alternative would be duplicating the bound in three places.
      # :reek:UtilityFunction
      def bounded_string?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= 128
      end

      def validate_hex!(value, label)
        return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

        raise ValidationError, "#{label} must be a 64-char hex digest"
      end

      def validate_direction!(direction)
        return if DIRECTIONS.include?(direction)

        raise ValidationError, "direction must be one of #{DIRECTIONS.join(', ')}"
      end

      def validate_actor!(actor_kind:, actor_id:, source:)
        unless ACTOR_KINDS.include?(actor_kind)
          raise ValidationError, "actor_kind must be one of #{ACTOR_KINDS.join(', ')}"
        end
        raise ValidationError, 'actor_id must be a bounded string' unless bounded_string?(actor_id)
        return if SOURCES.include?(source)

        raise ValidationError, "source must be one of #{SOURCES.join(', ')}"
      end

      def validate_times!(decided_at:, expires_at:)
        unless decided_at.is_a?(Time) && expires_at.is_a?(Time)
          raise ValidationError, 'decided_at and expires_at must be Time values'
        end
        raise ValidationError, 'expires_at must follow decided_at' unless expires_at > decided_at
      end

      def validate_status!(status)
        return if STATUSES.include?(status)

        raise ValidationError, "status must be one of #{STATUSES.join(', ')}"
      end

      # The lifecycle constraints are parametric on status: each status owns a
      # different field requirement, and the validation IS that dispatch.
      # :reek:ControlParameter, :reek:NilCheck
      def validate_claim!(status:, claim_owner:, claim_fence:, claim_expires_at:)
        if status == 'claimed'
          fields = [claim_owner, claim_fence, claim_expires_at]
          if fields.any?(&:nil?)
            raise ValidationError, 'a claimed decision needs claim_owner, claim_fence and claim_expires_at'
          end
        end
        return unless status == 'pending' &&
                      [claim_owner, claim_fence, claim_expires_at].any? { |field| !field.nil? }

        raise ValidationError, 'a pending decision carries no claim fields'
      end

      # The lifecycle constraints are parametric on status: each status owns a
      # different field requirement, and the validation IS that dispatch.
      # :reek:ControlParameter, :reek:NilCheck
      def validate_consumption!(status:, consumed_at:)
        consumed = !consumed_at.nil?
        consumed_status = status == 'consumed'
        error =
          if consumed_status && !consumed
            'a consumed decision needs consumed_at'
          elsif consumed && !consumed_status
            'a non-consumed decision carries no consumed_at'
          end
        raise ValidationError, error if error
      end

      def validate_id!(decision_id:)
        validate_hex!(decision_id, 'decision_id')
      end
    end
  end
end
