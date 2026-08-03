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
        stored_scopes = normalize(stored, "scopes")
        current_scopes = normalize(current, "scopes")
        stored_caps = normalize(stored, "capabilities")
        current_caps = normalize(current, "capabilities")

        kept_scopes = stored_scopes & current_scopes
        kept_caps = stored_caps & current_caps
        removed_scopes = stored_scopes - current_scopes
        removed_caps = stored_caps - current_caps

        status =
          if removed_scopes.empty? && removed_caps.empty?
            :granted
          elsif kept_scopes.empty? && kept_caps.empty?
            :revoked
          else
            :narrowed
          end

        {
          "status" => status,
          "effective" => {
            "scopes" => kept_scopes.sort,
            "capabilities" => kept_caps.sort
          },
          "removed_scopes" => removed_scopes.sort,
          "removed_capabilities" => removed_caps.sort
        }.freeze
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

      def normalize(grant, key)
        values = grant.is_a?(Hash) ? grant.fetch(key, []) : []
        unless values.is_a?(Array)
          raise Tamoz::ConfigurationError, "grant #{key} must be an array"
        end
        values.map { |value| String(value) }.uniq
      end
      private_class_method :normalize
    end
  end
end
