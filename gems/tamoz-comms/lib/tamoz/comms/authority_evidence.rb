# frozen_string_literal: true

require_relative 'errors'

module Tamoz
  module Comms
    # ADR-049: approval authority is gated on evidence strength, not transport.
    # The lattice is closed and totally ordered:
    #
    #   chat_bound  <  filesystem_operator
    #
    # A bound Telegram correspondent supplies `chat_bound`; an authenticated
    # local operator supplies `filesystem_operator`. Only the two sanctioned
    # factories mint instances — there is deliberately no mapping from actor
    # kind, source, or serialized payload to evidence, because deriving
    # operator evidence from a caller-supplied value is exactly the privilege
    # widening ADR-049 forbids (INV-C).
    #
    # The class-level structure is the closed-lattice contract itself: two
    # levels, one total order, one persistence round-trip.
    # :reek:MissingSafeMethod -- every `validate_*` raises by construction;
    #   a "safe" variant would be a lie.
    # :reek:FeatureEnvy -- `<=>` and `==` necessarily read the other lattice
    #   member being compared; that IS the value contract.
    class AuthorityEvidence
      include Comparable

      CHAT_BOUND = 'chat_bound'
      FILESYSTEM_OPERATOR = 'filesystem_operator'
      LEVELS = [CHAT_BOUND, FILESYSTEM_OPERATOR].freeze

      attr_reader :level

      def self.chat_bound = new(CHAT_BOUND)

      def self.filesystem_operator = new(FILESYSTEM_OPERATOR)

      # Round-trips a persisted lattice member (the pinned prompt field); a
      # value that is not a member is rejected, never coerced to a weaker one.
      def self.from(level)
        new(level)
      end

      def initialize(level)
        raise ValidationError, "evidence must be one of #{LEVELS.join(', ')}" unless LEVELS.include?(level)

        @level = level
        freeze
      end

      def <=>(other)
        return nil unless other.is_a?(AuthorityEvidence)

        LEVELS.index(level) <=> LEVELS.index(other.level)
      end

      def ==(other)
        other.is_a?(AuthorityEvidence) && level == other.level
      end
      alias eql? ==

      def hash = level.hash

      def chat_bound? = level == CHAT_BOUND

      def filesystem_operator? = level == FILESYSTEM_OPERATOR

      def to_s = level
    end
  end
end
