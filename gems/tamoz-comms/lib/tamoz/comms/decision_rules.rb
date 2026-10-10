# frozen_string_literal: true

require_relative 'errors'
require_relative 'authority_evidence'
require_relative 'surface_descriptor'

module Tamoz
  module Comms
    # The rules a DecisionRecord must satisfy: identity, actor, audit trail, time window and the
    # lifecycle fields each status requires.
    # :reek:MissingSafeMethod, :reek:FeatureEnvy, :reek:NilCheck
    module DecisionRules
      module_function

      def validate!(record)
        validate_identity!(record)
        validate_actor!(record)
        validate_audit!(record)
        validate_times!(record)
        validate_lifecycle!(record)
        validate_hex!(record.decision_id, 'decision_id')
      end

      def validate_identity!(record)
        unless bounded_string?(record.thread_id) && bounded_string?(record.occurrence_id)
          raise ValidationError, 'decision identity fields must be bounded strings'
        end

        validate_hex!(record.interrupt_digest, 'interrupt_digest')
        member!(record.direction, DecisionRecord::DIRECTIONS, 'direction')
      end

      def validate_actor!(record)
        raise ValidationError, 'actor_id must be a bounded string' unless bounded_string?(record.actor_id)

        kind = record.actor_kind
        source = record.source
        return if kind == 'os_user' && source == 'cli'
        return if SurfaceDescriptor.valid_kind?(source) && kind == "#{source}_user"

        raise ValidationError, 'actor_kind and source must name one channel kind (or os_user with cli)'
      end

      # An evidence level, when recorded, must be a lattice member — rejected, never coerced (ADR-049).
      def validate_audit!(record)
        AuthorityEvidence.from(record.evidence) unless record.evidence.nil?
        return if record.reason.nil? || bounded_string?(record.reason)

        raise ValidationError, 'reason must be a bounded string'
      end

      def validate_times!(record)
        decided = record.decided_at
        expires = record.expires_at
        raise ValidationError, 'decided_at and expires_at must be Time values' unless [decided, expires].all?(Time)
        raise ValidationError, 'expires_at must follow decided_at' unless expires > decided
      end

      # Each status owns a different field requirement.
      def validate_lifecycle!(record)
        member!(record.status, DecisionRecord::STATUSES, 'status')
        validate_claim!(record)
        consumed = !record.consumed_at.nil?
        raise ValidationError, 'a consumed decision needs consumed_at' if record.consumed? && !consumed
        raise ValidationError, 'a non-consumed decision carries no consumed_at' if consumed && !record.consumed?
      end

      def validate_claim!(record)
        claim = [record.claim_owner, record.claim_fence, record.claim_expires_at]
        if record.claimed? && claim.any?(&:nil?)
          raise ValidationError, 'a claimed decision needs claim_owner, claim_fence and claim_expires_at'
        end
        raise ValidationError, 'a pending decision carries no claim fields' if record.pending? && claim.any?
      end

      def bounded_string?(value) = value.is_a?(String) && !value.empty? && value.bytesize <= 128

      def validate_hex!(value, label)
        return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

        raise ValidationError, "#{label} must be a 64-char hex digest"
      end

      def member!(value, set, label)
        raise ValidationError, "#{label} must be one of #{set.join(', ')}" unless set.include?(value)
      end
    end
  end
end
