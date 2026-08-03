# frozen_string_literal: true

module Tamoz
  module Stream
    # P14-P (plan §7/C6, design §11) — the read-only interlock reader.
    # Production code sees ONLY this surface: `ready?` and `state`, never a
    # write API. The mutable harness lives in the test tree; a dependency-
    # direction test proves production `tamoz-stream` (and the healing paths)
    # cannot reference the harness or any write API.
    #
    # The interlock is independently controlled (external safety mechanism):
    # Tamoz can never disable, weaken, emulate, or heal around it. An interlock
    # read failure raises InterlockUnavailableError — FAIL CLOSED, no dispatch.
    module InterlockReader
      def ready?(interlock_id)
        raise NotImplementedError
      end

      def state(interlock_id)
        raise NotImplementedError
      end
    end

    # P14-P/C2 — the action boundary. Command dispatch happens INSIDE the
    # episode's graph execution (the terminal node of the same durable run that
    # produced the Decision), so the journal's active-execution precondition
    # holds. Before the simulator receives a Command, policy REVALIDATES every
    # check (design §11) and the interlock is re-read at the NARROWEST point —
    # immediately before delivery. The simulator asserts ready at delivery and
    # rejects a Command delivered after the interlock tripped (C6 TOCTOU).
    #
    # The boundary never calls a physical effector: the ONLY effector is the
    # simulator, and it receives a typed Command plus a narrow credential.
    module ActionBoundary
      # Revalidate an accepted intent against the current state and the
      # interlock. Returns the validated Command or a typed refusal.
      #
      # @param intent [Hash] the typed ActionIntent (risk class, target, etc.).
      # @param snapshot_digest [String] the SituationSnapshot digest the plan
      #   was bound to (invariant 49) — a superseded episode's late Decision
      #   dies here on mismatch.
      # @param current_snapshot_digest [String] the current snapshot digest.
      # @param revalidate [Proc] the post-approval deterministic revalidation
      #   (freshness, completeness, health, quorum, bounds) -> true/false.
      # @param interlock [InterlockReader] the read-only interlock.
      # @param interlock_id [String] the interlock to check.
      # @param risk_class [Symbol] the intent's risk class.
      # @return [Hash] {"deliver" => true, "command" => {...}} or
      #   {"deliver" => false, "reason" => String}
      def self.revalidate_and_check(intent:, snapshot_digest:, current_snapshot_digest:,
                                    revalidate:, interlock:, interlock_id:,
                                    risk_class:)
        # Freshness: the snapshot the plan was bound to must be current.
        unless snapshot_digest == current_snapshot_digest
          return {"deliver" => false, "reason" => "snapshot_superseded"}
        end

        # Post-approval revalidation repeats every check (approval does not
        # freeze reality).
        unless revalidate.call(intent)
          return {"deliver" => false, "reason" => "revalidation_failed"}
        end

        # R4 is advisory only — never dispatched.
        if risk_class == :r4_advisory
          return {"deliver" => false, "reason" => "r4_advisory_never_dispatched"}
        end

        # The interlock is re-read at the narrowest point — immediately before
        # delivery (C6 TOCTOU). A read failure FAILS CLOSED.
        ready = begin
          interlock.ready?(interlock_id)
        rescue StreamError
          raise InterlockUnavailableError, "interlock read failed; no dispatch"
        end
        unless ready
          return {"deliver" => false, "reason" => "interlock_not_ready"}
        end

        {"deliver" => true, "command" => {"intent" => intent, "interlock_id" => interlock_id}}
      end

      # C6: the SIMULATOR asserts ready at delivery and rejects a Command
      # delivered after the interlock tripped. This is the effector-side half
      # of the TOCTOU guard.
      def self.simulator_accepts(command:, interlock:, interlock_id:)
        unless interlock.ready?(interlock_id)
          raise InterlockUnavailableError,
                "command dispatched while interlock tripped"
        end
        true
      end
    end
  end
end
