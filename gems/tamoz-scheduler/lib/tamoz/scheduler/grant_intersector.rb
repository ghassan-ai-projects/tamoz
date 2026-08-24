# frozen_string_literal: true

module Tamoz
  module Scheduler
    # P13-C (design §9, plan §7; invariant 40) — the grant intersection.
    #
    # A scheduled task is delayed authority, not a future blank cheque. The
    # schedule stores its MAXIMUM grant; at materialization (claim-time) and at
    # execution (via the agent's existing session-authority re-binding) that
    # stored grant is intersected with the CURRENT operator policy. This is the
    # pinned enforcement point — the SAME pure function at both seams, so an
    # old schedule can never retain removed authority.
    #
    # The grant shape is intentionally small and generic: a set of scopes plus
    # a set of capability names. The operator policy supplies the same shape.
    # The intersection result is one of:
    #
    # - :granted  — the stored grant is fully within current policy.
    # - :narrowed — some stored capability/scope is no longer authorized; the
    #               occurrence may run ONLY under the effective intersection.
    # - :revoked  — nothing survives the intersection; the occurrence is
    #               skipped/escalated, never run with a silently substituted
    #               grant.
    #
    # In-flight semantics (plan §7): an occurrence whose plan is already
    # accepted either completes under the accepted plan (invariant 26) or is
    # cancelled at the next safe barrier. This intersector decides at claim and
    # execution; it never fabricates a grant the current policy would deny.
    module GrantIntersector
      INTERSECTION_DOMAIN = "tamoz.scheduler.grant_intersection.v1\n"

      module_function

      # @param stored [Hash] the schedule's stored maximum grant
      #   ({"scopes" => [...], "capabilities" => [...]}).
      # @param current [Hash] the operator policy at the enforcement point.
      # @return [Hash] {status: :granted|:narrowed|:revoked, effective: Hash,
      #                 removed_scopes: [...], removed_capabilities: [...]}
      def intersect(stored, current)
        stored_grant, current_grant = normalize_grants(stored, current)
        effective = grant_intersection(stored_grant, current_grant)
        removed = removed_grant(stored_grant, current_grant)
        build_result(intersection_status(effective, removed), effective, removed)
      end

      # Whether the schedule may still materialize under the current policy.
      # `:narrowed` is allowed ONLY when the caller is prepared to run under
      # the intersection; `:revoked` is always refused. Returns the effective
      # grant or nil.
      def effective_grant(stored, current, allow_narrowed: true)
        result = intersect(stored, current)
        case result.fetch("status")
        when :granted
          result.fetch("effective")
        when :narrowed
          allow_narrowed ? result.fetch("effective") : nil
        when :revoked
          nil
        end
      end

      def normalize_grants(stored_input, current_input)
        stored_scopes, current_scopes = normalize_pair(stored_input, current_input, "scopes")
        stored_caps, current_caps = normalize_pair(stored_input, current_input, "capabilities")
        [
          { "scopes" => stored_scopes, "capabilities" => stored_caps },
          { "scopes" => current_scopes, "capabilities" => current_caps }
        ]
      end
      private_class_method :normalize_grants

      def normalize_pair(left, right, key)
        [normalize_values(left, key), normalize_values(right, key)]
      end
      private_class_method :normalize_pair

      def normalize_values(grant, key)
        values = grant.is_a?(Hash) ? grant.fetch(key, []) : []
        unless values.is_a?(Array)
          raise Tamoz::ConfigurationError, "grant #{key} must be an array"
        end
        values.map { |value| String(value) }.uniq
      end
      private_class_method :normalize_values

      def grant_intersection(maximum, policy)
        {
          "scopes" => maximum.fetch("scopes") & policy.fetch("scopes"),
          "capabilities" => maximum.fetch("capabilities") & policy.fetch("capabilities")
        }
      end
      private_class_method :grant_intersection

      def removed_grant(maximum, policy)
        {
          "scopes" => maximum.fetch("scopes") - policy.fetch("scopes"),
          "capabilities" => maximum.fetch("capabilities") - policy.fetch("capabilities")
        }
      end
      private_class_method :removed_grant

      def intersection_status(effective, removed)
        return :granted if removed.values.all?(&:empty?)
        return :revoked if effective.values.all?(&:empty?)

        :narrowed
      end
      private_class_method :intersection_status

      def build_result(status, effective, removed)
        {
          "status" => status,
          "effective" => sorted_grant(effective),
          "removed_scopes" => removed.fetch("scopes").sort,
          "removed_capabilities" => removed.fetch("capabilities").sort
        }.freeze
      end
      private_class_method :build_result

      def sorted_grant(grant)
        {
          "scopes" => grant.fetch("scopes").sort,
          "capabilities" => grant.fetch("capabilities").sort
        }
      end
      private_class_method :sorted_grant
    end
  end
end
