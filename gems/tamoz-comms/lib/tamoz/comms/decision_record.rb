# frozen_string_literal: true

require 'time'

require_relative 'canonical'
require_relative 'errors'
require_relative 'shapes'
require_relative 'interrupt_digest'
require_relative 'authority_evidence'
require_relative 'decision_rules'

module Tamoz
  module Comms
    DecisionRecord = Data.define(:decision_id, :thread_id, :occurrence_id, :interrupt_digest,
                                 :direction, :actor_kind, :actor_id, :source,
                                 :decided_at, :expires_at, :status,
                                 :claim_owner, :claim_fence, :claim_expires_at, :consumed_at,
                                 :evidence, :reason)

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
    # :reek:MissingSafeMethod -- every `validate_*!` raises by construction.
    class DecisionRecord
      DIRECTIONS = %w[approve deny].freeze
      STATUSES = %w[pending claimed consumed].freeze
      DEFAULT_TTL_S = 900
      ID_DOMAIN = 'tamoz.comms.decision.v1'
      WIRE_TIME = '%Y-%m-%dT%H:%M:%S.%6NZ'
      TIMES = %i[decided_at expires_at claim_expires_at consumed_at].freeze
      OPTIONAL = { claim_owner: nil, claim_fence: nil, claim_expires_at: nil, consumed_at: nil,
                   evidence: nil, reason: nil }.freeze
      ID_FIELDS = %i[thread_id occurrence_id interrupt_digest direction actor_kind actor_id source decided_at].freeze

      def initialize(**fields)
        super(**OPTIONAL, **fields.to_h { |name, value| [name, TIMES.include?(name) ? Shapes.utc(value) : value] })
        DecisionRules.validate!(self)
      end

      # Builds a pending decision from a live interrupt set, deriving the
      # interrupt digest and the decision id. `decided_at` defaults to now and
      # is part of the id: a later re-decision of the SAME question is a NEW
      # decision (single-use consumption), never a duplicate of a consumed one.
      # `interrupt_digest:` in `fields` binds a prompt's pre-computed digest (ADR-043).
      def self.build(interrupts:, decided_at: Time.now.utc, ttl_s: DEFAULT_TTL_S, **fields)
        fields = fields.merge(direction: fields.fetch(:direction).to_s, decided_at: decided_at.getutc)
        fields[:interrupt_digest] ||= InterruptDigest.of(interrupts)
        new(**fields, decision_id: decision_id_for(fields), expires_at: fields.fetch(:decided_at) + ttl_s,
                      status: 'pending')
      end

      def self.decision_id_for(fields)
        direction = fields.fetch(:direction)
        raise ValidationError, "direction must be one of #{DIRECTIONS.join(', ')}" unless DIRECTIONS.include?(direction)

        Canonical.hexdigest(ID_DOMAIN, fields.values_at(*ID_FIELDS))
      end

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

      def expired?(now) = now >= expires_at

      def pending? = status == 'pending'

      def claimed? = status == 'claimed'

      def consumed? = status == 'consumed'

      # @return [Hash] the durable string-keyed wire form.
      def wire
        to_h.to_h { |name, value| [name.to_s, TIMES.include?(name) ? value&.strftime(WIRE_TIME) : value] }
      end

      # @param wire [Hash] a hash produced by `wire` (or an equivalent writer).
      def self.from_wire(wire)
        new(**members.to_h do |name|
          value = wire[name.to_s]
          [name, TIMES.include?(name) && value ? Time.parse(value) : value]
        end)
      end
    end
  end
end
