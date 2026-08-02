# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    # The node bodies of the durable session graph. Each public method is one graph
    # node: it reads the frozen committed snapshot, may call the model or a tool
    # through the effect journal, and returns a partial state update that the barrier
    # commits.
    #
    # Every node must be safe to re-enter from its first line (invariant 4): after a
    # crash the engine restarts the node, and correctness comes from the effect journal
    # returning recorded receipts, not from the node remembering anything.
    #
    # Routing is explicit through the `next_node` channel rather than inferred from
    # state, so a resumed run takes the same edge the crashed run would have taken.
    class SessionNodes
      MAX_OBSERVATION_BYTES = Runtime::MAX_OBSERVATION_BYTES
      MAX_TASK_BYTES = Runtime::MAX_TASK_BYTES
      GRAPH_VERSION = "1"
      BEHAVIOR_VERSION = "tamoz.agent.session/1"

      attr_reader :toolbox, :max_plan_attempts, :max_repair_attempts, :model_call_safety,
                  :profile, :mcp

      def initialize(
        model:,
        toolbox:,
        max_plan_attempts:,
        max_repair_attempts:,
        model_call_safety:,
        profile: nil,
        mcp: nil,
        profile_roles: nil,
        profile_budgets: nil,
        memory: nil,
        memory_owner: nil
      )
        @model = model
        @toolbox = toolbox
        @max_plan_attempts = max_plan_attempts
        @max_repair_attempts = max_repair_attempts
        @model_call_safety = model_call_safety
        @profile = profile
        # P10 §3: the caller-supplied MCP source. Duck-typed; nil when the session
        # has no MCP surface, in which case every branch below is inert and the
        # session behaves byte-identically to before P10.
        @mcp = mcp
        # P11: the per-tenant memory surface (Tamoz::Agent::Memory::Engine) or
        # nil. Nil keeps every memory branch inert: intake records the "none"
        # legacy sentinel, retrieval injects nothing, and the prompt surface is
        # byte-identical to before P11.
        @memory = memory
        @memory_owner = memory_owner
        # DR-5 D1 (RC5): the post-override per-role {provider:, model:} tuples are
        # computed by the caller (cli.rb's shared resolution function, the SAME
        # one build_model uses) and folded into the session record at intake —
        # the seam is named, not left to the implementer. nil means "no overrides":
        # intake then records the file values, which is f(model_roles, no
        # overrides) — still no independent data.
        @profile_roles = profile_roles
        @profile_budgets = profile_budgets
        verify_profile_roles!(profile_roles)
        freeze
      end

      # --- nodes ---------------------------------------------------------------

      def intake(state, context)
        raw_task = state.fetch(:task)
        if raw_task.is_a?(Hash) && raw_task["cancel"] == true
          return {
            next_node: "terminal",
            terminal_reason: "cancelled_by_user"
          }
        end

        task = String(raw_task).strip
        raise ArgumentError, "task must not be empty" if task.empty?
        if task.bytesize > MAX_TASK_BYTES
          raise ArgumentError, "task exceeds #{MAX_TASK_BYTES} bytes"
        end

        # P11-W / DR-1: at the FIRST INTAKE OF A THREAD the pending behavior
        # transition is claimed (Store CAS) before any checkpoint write.
        claimed = claim_behavior_transition(context)
        {
          task:,
          phase: toolbox.action_capable? ? "discovery" : "read_only",
          repair_attempt: 0,
          step_cursor: 0,
          next_node: "deliberate",
          **claimed_behavior_channel(claimed),
          session: SessionRecords.build(
            "session",
            session_id: String(context.thread_id),
            task:,
            task_digest: Digest::SHA256.hexdigest(task),
            root: toolbox.root.to_s,
            graph_version: GRAPH_VERSION,
            behavior_version: behavior_version(claimed),
            tool_catalog_digest: toolbox.catalog_digest,
            created_at_ms: 0,
            **profile_binding,
            **skill_binding,
            **mcp_binding,
            **egress_binding,
            **behavior_binding(claimed),
            **memory_binding
          )
        }
      end

      # P11 (C4): the per-session memory snapshot. A memory-enabled session
      # records the layers/policy/catalog-digest snapshot; a memory-free
      # session records nothing and the "none" legacy sentinel is filled at
      # load (zero memory injection, identical prefix digest).
      def memory_binding
        return {} unless @memory

        {
          memory_epoch: {
            "layers" => %w[experience knowledge wisdom],
            "retrieval_policy" => "explicit_plus_automatic",
            "catalog_digest" => toolbox.prompt_surface_digest
          }
        }
      end

      # P11-W / DR-1: a promoted Wisdom (or heuristic) transition is consumed
      # at the FIRST INTAKE OF A THREAD. Claim (Store CAS, before any
      # checkpoint write); the checkpoint commit IS the apply (the session
      # record carries behavior_version_after + the pinned snapshot + the
      # extended prompt-surface digest + epoch_reason); the next node
      # finalizes. Existing threads (resume/continue/redirect, boundary false)
      # never re-run intake, so they stay pinned.
      def claim_behavior_transition(context)
        return nil unless @memory

        pending = @memory.transitions.pending_transition
        return nil unless pending

        @memory.transitions.claim(
          transition_id: pending.transition_id,
          owner: "intake:#{context.thread_id}",
          attempt: 1
        )
      rescue Memory::BehaviorTransitionClaimConflictError
        # Another consumer claimed the same transition; this thread stays on
        # the prior active version.
        nil
      end

      # The behavior_transition_claim state channel (the finalize hook for the
      # next node), or {} when nothing was claimed.
      def claimed_behavior_channel(claimed)
        return {} unless claimed

        {behavior_transition_claim: [claimed.transition_id]}
      end

      # The session-record binding for the claimed transition: the new behavior
      # version, the pinned snapshot digest + inline content, the extended
      # prompt-surface digest (the cache epoch moved, invariant 16), and
      # `epoch_reason` = the transition id.
      def behavior_binding(claimed)
        return {} unless claimed

        snapshot = @memory.transitions.snapshot_for(claimed.behavior_snapshot_digest)
        {
          epoch_reason: claimed.transition_id,
          behavior_snapshot_digest: claimed.behavior_snapshot_digest,
          behavior_snapshot: snapshot,
          prompt_surface_digest: Memory::BehaviorTransition.extended_prompt_surface_digest(
            toolbox:, behavior_snapshot_digest: claimed.behavior_snapshot_digest
          )
        }
      end

      # The behavior version recorded at intake: the claimed transition's AFTER
      # version when adopting; the control record's active version when a
      # transition is already active; the baseline otherwise.
      def behavior_version(claimed)
        return claimed.behavior_version_after if claimed

        if @memory && @memory.transitions.active.fetch("active_version") != BEHAVIOR_VERSION
          @memory.transitions.active.fetch("active_version")
        else
          BEHAVIOR_VERSION
        end
      end

      # P9 §7: the session pins the exact skill catalog it was planned against.
      # `Session#verify_skill_binding!` compares this on resume and stops rather
      # than continuing an accepted plan under changed instructions (invariant 41).
      def skill_binding
        {
          skill_epoch: toolbox.skill_epoch,
          prompt_surface_digest: toolbox.prompt_surface_digest
        }
      end

      # P10 §5: a session that used an MCP capability pins the catalog digests it
      # ran against as `mcp_catalogs` in the session record. `Session#verify_mcp_binding!`
      # compares this on resume and stops with the typed
      # `McpCatalogSnapshotUnavailableError` rather than continuing under changed
      # server schemas (epoch rules). A session with no MCP source pins nothing
      # (the legacy sentinel is the empty hash at load time).
      def mcp_binding
        return {} unless mcp && !mcp.catalogs.empty?

        {mcp_catalogs: mcp.mcp_catalogs}
      end

      # P17 (correction 5): a session that ran under a profile carrying an
      # `egress:` section pins the canonical egress declaration as `egress_pin`.
      # `Session#verify_egress_binding!` compares this on resume and stops with
      # the typed `EgressBindingUnavailableError` rather than continuing an
      # accepted plan under a changed network policy (invariant 35/36). A session
      # without a profile, or whose profile has no egress section, pins nothing
      # (the legacy sentinel is the empty hash at load time).
      def egress_binding
        return {} unless profile && profile.egress

        {egress_pin: Deliberation.canonical(profile.egress)}
      end

      # P8: a profile-bound session pins its authority in the session record. The
      # constructor has already verified the toolbox matches the profile surface
      # (§5.2), so intake records the identity plus the exact authority snapshot
      # (§5.4) that a later resume replays instead of re-reading the profile file.
      # Editing the file afterwards cannot reach this record.
      #
      # DR-5 D1: the post-override `profile_roles` tuples and the validated
      # `profile_budgets` ride along in the same binding — the accurate record of
      # what actually ran (P11/P12 consumers read this, never a second table).
      def profile_binding
        return {} unless profile

        {
          profile_id: profile.profile_id,
          profile_digest: profile.canonical_digest,
          profile_authority: profile.authority_snapshot,
          profile_roles: recorded_profile_roles,
          profile_budgets: recorded_profile_budgets
        }
      end

      # DR-5 D1: the recorded roles are exactly f(model_roles, overrides). The
      # caller-supplied value (cli.rb) is already post-override; the default is
      # the file values, i.e. f with no overrides. Either way there is NO
      # independent data — only provider/model strings, never a model instance
      # and never a credential.
      def recorded_profile_roles
        return @profile_roles if @profile_roles
        return {} unless profile

        profile.model_roles.transform_values do |role|
          {"provider" => role.fetch("provider"), "model" => role.fetch("model")}
        end
      end

      def recorded_profile_budgets
        return @profile_budgets unless @profile_budgets.nil?
        return {} unless profile

        profile.budgets
      end

      # DR-5 A2: `profile_roles` is a durable record — it must be plain data
      # (strings only), never a model instance, never a provider object. Refusal
      # is typed and terminal, before any checkpoint write.
      def verify_profile_roles!(roles)
        return unless roles

        unless roles.is_a?(Hash)
          raise ProfilePolicyError,
                "profile_roles must be a mapping of role name to {provider, model}"
        end
        roles.each do |name, entry|
          unless entry.is_a?(Hash) && entry.keys.sort == %w[model provider] &&
                 entry["provider"].is_a?(String) && entry["model"].is_a?(String)
            raise ProfilePolicyError,
                  "profile role #{name.inspect} must record exactly string provider and model"
          end
        end
      end
      private :verify_profile_roles!

      def deliberate(state, context)
        # A cancel sentinel routed by intake must reach terminal without any model I/O.
        if state.fetch(:next_node) == "terminal" && state.fetch(:terminal_reason) == "cancelled_by_user"
          return {}
        end

        # P11-W / DR-1: the intake's checkpoint commit IS the apply; this node
        # finalizes the claimed transition (Store CAS) before any model call.
        # Idempotent by transition_id.
        finalize_behavior_claim(state)

        phase = state.fetch(:phase).to_sym
        repair_attempt = state.fetch(:repair_attempt)
        task = state.fetch(:task)
        evidence = state.fetch(:observations).map { |record| observation_payload(record) }
        allowed_tools = allowed_tool_names(phase)
        mcp_tools = mcp_planning_surface(allowed_tools)
        planning_context = planning_context_for(state, phase)
        ambiguity = state.fetch(:provider_ambiguity)
        plans = []
        reviews = []
        feedback = []

        max_plan_attempts.times do |offset|
          attempt = offset + 1
          plan_id = "#{phase}.#{repair_attempt}.#{attempt}"
          call = model_call(
            context,
            stage: :plan,
            system: Deliberation::PLAN_SYSTEM,
            prompt: Deliberation.planning_prompt(
              task,
              phase,
              allowed_tools,
              evidence,
              feedback,
              planning_context,
              toolbox:,
              mcp_tools:
            ),
            call_index: attempt * 2
          )
          return blocked_update(call, "model call outcome is unknown") unless call.status == :succeeded

          ambiguity += 1 if call.attempt_number > 1
          plan = nil
          begin
            plan = Plan.parse(call.value)
          rescue ProtocolError => error
            feedback = [error.message]
            reviews << SessionRecords.build(
              "review",
              review_id: "#{plan_id}.protocol",
              plan_id:,
              plan_digest: Digest::SHA256.hexdigest(String(call.value)),
              layer: "protocol",
              decision: "revise",
              issues: feedback,
              rationale: "the planner did not return a usable plan document"
            )
          end
          next unless plan

          plan_hash = Deliberation.canonical(plan.to_h)
          plan_digest = SessionRecords.digest(plan_hash)
          begin
            plans << SessionRecords.build(
              "plan",
              plan_id:,
              phase: phase.to_s,
              attempt:,
              plan: plan_hash,
              plan_digest:
            )
          rescue Tamoz::SensitiveValueError => error
            # P17 W6 (correction 6): a plan whose step arguments carry a
            # credential VALUE is rejected at the checkpoint boundary — the
            # value never enters the session record, journal, or audit. The
            # model gets the typed reason as revision feedback and replans
            # without the value; nothing was committed and no call was issued.
            feedback = [error.message]
            reviews << SessionRecords.build(
              "review",
              review_id: "#{plan_id}.credentials",
              plan_id:,
              plan_digest:,
              layer: "protocol",
              decision: "revise",
              issues: feedback,
              rationale: "the plan step arguments carry a credential-shaped value"
            )
            next
          end

          structural = Deliberation.structural_issues(
            plan,
            phase:,
            allowed_tools:,
            toolbox:,
            mcp: @mcp
          )
          reviews << SessionRecords.build(
            "review",
            review_id: "#{plan_id}.structural",
            plan_id:,
            plan_digest:,
            layer: "structural",
            decision: structural.empty? ? "accept" : "revise",
            issues: structural,
            rationale: "deterministic structural review"
          )
          unless structural.empty?
            feedback = structural
            next
          end

          review_call = model_call(
            context,
            stage: :review,
            system: Deliberation::REVIEW_SYSTEM,
            prompt: Deliberation.review_prompt(
              task,
              plan,
              phase:,
              evidence:,
              planning_context:
            ),
            call_index: (attempt * 2) + 1
          )
          unless review_call.status == :succeeded
            return blocked_update(review_call, "model call outcome is unknown")
          end

          ambiguity += 1 if review_call.attempt_number > 1
          review = nil
          begin
            review = Deliberation.parse_review(review_call.value)
          rescue ProtocolError => error
            feedback = [error.message]
            reviews << SessionRecords.build(
              "review",
              review_id: "#{plan_id}.semantic",
              plan_id:,
              plan_digest:,
              layer: "protocol",
              decision: "revise",
              issues: feedback,
              rationale: "the reviewer did not return a usable review document"
            )
          end
          next unless review

          reviews << SessionRecords.build(
            "review",
            review_id: "#{plan_id}.semantic",
            plan_id:,
            plan_digest:,
            layer: "semantic",
            decision: review.fetch("decision"),
            issues: review.fetch("issues"),
            rationale: review.fetch("rationale")
          )
          case review.fetch("decision")
          when "accept"
            return accept_plan(
              state,
              plan:,
              plan_id:,
              plan_digest:,
              plan_hash:,
              phase:,
              plans:,
              reviews:,
              ambiguity:
            )
          when "needs_input"
            return clarify_update(
              state,
              context:,
              plan_id:,
              plan_digest:,
              review:,
              phase:,
              repair_attempt:,
              plans:,
              reviews:,
              ambiguity:
            )
          end

          feedback = review.fetch("issues")
        end

        plan_rejected(state, plans:, reviews:, ambiguity:, phase:, repair_attempt:)
      end

      def step_gate(state, context)
        accepted = state.fetch(:accepted_plan)
        steps = accepted.fetch("plan").fetch("steps")
        cursor = state.fetch(:step_cursor)
        return {next_node: "evaluate"} if cursor >= steps.length

        step = steps.fetch(cursor)
        tool = step["tool"]
        return {next_node: "step_execute"} if tool.nil?

        # `effect_intent` and `preview` run the filesystem preflight before any
        # interrupt is raised and before any journal entry exists. A repairable
        # rejection here has prepared nothing, so it is pure evidence.
        begin
          # D-8 Fix A (RC-2): resolve an absent mutation digest exactly once, here.
          # The SAME resolved arguments flow into the intent, the preview, and the
          # approval descriptor; `prepare_patch`'s equality check re-verifies them at
          # execution, so preview and execution always describe the same bytes.
          resolved_arguments = resolved_effect_arguments(step.fetch("arguments"), tool)
          intent = build_intent(step, accepted, resolved_arguments)
          unless approval_required?(tool)
            return {next_node: "step_execute", effect_intents: [intent]}
          end

          budget = maximum_effect_output_bytes(tool)
          if observation_bytes(state) + budget > MAX_OBSERVATION_BYTES
            raise ToolError, "insufficient observation budget for #{tool}"
          end

          preview = preview_for(tool, resolved_arguments)
        rescue ToolArgumentError => error
          return tool_failure_update(
            state,
            step:,
            tool:,
            # P16: map the core taxonomy name back to the public
            # `Tamoz::Agent::Tool*` spelling (see `Tamoz::Core::TOOL_ERROR_CLASS_NAMES`).
            error_class: Tamoz::Core.serialized_tool_error_name(error.class.name),
            reason: error.message
          )
        end
        preview_digest = Digest::SHA256.hexdigest(preview)
        descriptor = {
          "kind" => "approve_tool",
          "session_id" => state.fetch(:session).fetch("session_id"),
          "plan_id" => accepted.fetch("plan_id"),
          "plan_digest" => accepted.fetch("plan_digest"),
          "step_id" => step.fetch("id"),
          "tool" => tool,
          "arguments" => resolved_arguments,
          "preview" => preview,
          "arguments_digest" => intent.fetch("arguments_digest"),
          "preview_digest" => preview_digest
        }
        answer = Tamoz.interrupt(descriptor, context)
        granted = answer == true || answer == "approve" || answer == "approved"
        approval = SessionRecords.build(
          "approval",
          approval_id: "#{accepted.fetch("plan_id")}.#{step.fetch("id")}",
          plan_id: accepted.fetch("plan_id"),
          plan_digest: accepted.fetch("plan_digest"),
          step_id: step.fetch("id"),
          tool:,
          arguments_digest: intent.fetch("arguments_digest"),
          preview_digest:,
          decision: granted ? "approve" : "deny"
        )
        unless granted
          return {
            approvals: [approval],
            next_node: "terminal",
            terminal_reason: "approval_denied"
          }
        end

        {
          approvals: [approval],
          effect_intents: [intent],
          next_node: "step_execute"
        }
      end

      def step_execute(state, context)
        accepted = state.fetch(:accepted_plan)
        steps = accepted.fetch("plan").fetch("steps")
        cursor = state.fetch(:step_cursor)
        step = steps.fetch(cursor)
        phase = state.fetch(:phase)
        tool = step["tool"]

        if tool.nil?
          return {
            step_cursor: cursor + 1,
            next_node: "evaluate",
            observations: [
              SessionRecords.build(
                "observation",
                phase:,
                repair_attempt: state.fetch(:repair_attempt),
                step_id: step.fetch("id"),
                output: "No tool required."
              )
            ]
          }
        end

        intent = find_intent(state, accepted, step)
        outcome = dispatch(context, intent, step)
        case outcome.status
        when :unknown
          return blocked_update(
            outcome,
            "effect outcome is unknown",
            step_id: step.fetch("id"),
            operation: intent.fetch("operation")
          )
        when :wait
          raise LeaseLostError,
                "another owner still holds effect #{outcome.effect_key}"
        when :failed
          unless repairable_outcome?(outcome)
            raise ToolError, tool_error_message(outcome)
          end

          return tool_failure_update(
            state,
            step:,
            tool:,
            error_class: tool_error_class(outcome),
            reason: tool_error_message(outcome),
            effect_receipt: SessionRecords.build(
              "effect_receipt",
              effect_key: outcome.effect_key,
              step_id: step.fetch("id"),
              operation: intent.fetch("operation"),
              safety: intent.fetch("safety"),
              status: "failed",
              attempt_number: outcome.attempt_number,
              reconciliation: outcome.reconciliation
            )
          )
        end

        output = String(outcome.value.fetch("output"))
        if observation_bytes(state) + output.bytesize > MAX_OBSERVATION_BYTES
          raise ToolError, "tool observations exceed #{MAX_OBSERVATION_BYTES} bytes"
        end

        observation_fields = {
          phase:,
          repair_attempt: state.fetch(:repair_attempt),
          step_id: step.fetch("id"),
          output:,
          tool:
        }
        observation_fields[:check] = outcome.value.fetch("check") if outcome.value.key?("check")
        update = {
          step_cursor: cursor + 1,
          next_node: "evaluate",
          observations: [SessionRecords.build("observation", **observation_fields)],
          effect_receipts: [
            SessionRecords.build(
              "effect_receipt",
              effect_key: outcome.effect_key,
              step_id: step.fetch("id"),
              operation: intent.fetch("operation"),
              safety: intent.fetch("safety"),
              status: "succeeded",
              attempt_number: outcome.attempt_number,
              reconciliation: outcome.reconciliation
            )
          ]
        }
        if outcome.value.key?("check")
          update[:check_passed] = outcome.value.fetch("check").fetch("passed")
        end
        update
      end

      def evaluate(state, _context)
        accepted = state.fetch(:accepted_plan)
        steps = accepted.fetch("plan").fetch("steps")
        cursor = state.fetch(:step_cursor)
        check = current_pass_check(state)

        # A repairable tool rejection short-circuits the rest of the plan: running the
        # remaining steps would only produce a configured-check failure that masks the
        # real reason. Only the action and repair phases have a repair budget, so in
        # discovery and read-only the failure stays evidence and the plan continues.
        failure = current_pass_tool_failure(state)
        if failure
          return bounded_repair(
            state,
            failure.fetch("failure_signature"),
            repeated_reason: "repeated_tool_failure"
          )
        end

        if check
          return {next_node: "verify", terminal_reason: "check_passed"} if check.fetch("passed")

          return failed_check(state, check)
        end
        return {next_node: "step_gate"} if cursor < steps.length

        case state.fetch(:phase)
        when "discovery"
          {next_node: "deliberate", phase: "action", step_cursor: 0}
        when "read_only"
          {next_node: "verify", terminal_reason: "completed"}
        else
          {next_node: "verify", terminal_reason: "completed_without_check"}
        end
      end

      def verify(state, context)
        accepted = state.fetch(:accepted_plan)
        plan = Plan.parse(accepted.fetch("plan"))
        review = last_semantic_review(state, accepted)
        observations = state.fetch(:observations).map { |record| observation_payload(record) }
        terminal_reason = state.fetch(:terminal_reason)
        verification_context =
          if toolbox.action_capable?
            {
              "configured_check_passed" => state.fetch(:check_passed),
              "terminal_reason" => terminal_reason
            }
          else
            {}
          end

        call = model_call(
          context,
          stage: :verify,
          system: Deliberation::VERIFY_SYSTEM,
          prompt: Deliberation.verification_prompt(
            state.fetch(:task),
            plan,
            review,
            observations,
            verification_context:
          ),
          call_index: 0
        )
        return blocked_update(call, "model call outcome is unknown") unless call.status == :succeeded

        document = Deliberation.parse_verification(call.value)
        satisfied = document.fetch("satisfied")
        evidence = document.fetch("evidence")
        if toolbox.action_capable? && !toolbox.checks.empty? &&
           state.fetch(:check_passed) != true
          satisfied = false
          evidence += ["framework: no configured check passed (#{terminal_reason})"]
        end

        {
          next_node: "terminal",
          provider_ambiguity: state.fetch(:provider_ambiguity) + (call.attempt_number > 1 ? 1 : 0),
          verification: SessionRecords.build(
            "verification",
            answer: document.fetch("answer"),
            satisfied:,
            evidence:,
            configured_check_passed: state.fetch(:check_passed) == true,
            terminal_reason:
          )
        }
      end

      def terminal(state, _context)
        verification = state[:verification]
        # P11 (scope item 7): memory writes at turn boundaries — a completed
        # bounded episode with an independently observed Outcome becomes an
        # Experience record (deterministic admission gate (a), provider-free).
        record_episode_memory(state, verification) if @memory
        {
          phase: "terminal",
          terminal: SessionRecords.build(
            "terminal",
            reason: state.fetch(:terminal_reason),
            satisfied: verification ? verification.fetch("satisfied") : false,
            blocked: state[:blocked]
          )
        }
      end

      private

      # P11-W / DR-1: finalize the intake's claimed behavior transition. The
      # checkpoint commit of the intake (the apply) has happened by the time
      # this node runs; finalize is idempotent by transition_id.
      def finalize_behavior_claim(state)
        return unless @memory

        Array(state.fetch(:behavior_transition_claim, [])).each do |transition_id|
          session_id = state[:session] && state[:session].fetch("session_id")
          @memory.transitions.finalize(transition_id:, consumed_by: session_id.to_s)
        rescue Memory::BehaviorTransitionClaimConflictError
          nil
        end
      end

      # P11-A: a completed bounded episode (terminal_reason in the completed
      # set with an independently observed verification outcome) is admitted as
      # Experience. Never a transcript; recalled content is excluded by the
      # admission boundary itself.
      def record_episode_memory(state, verification)
        return unless %w[completed completed_without_check check_passed].include?(state.fetch(:terminal_reason))
        return unless verification && verification.fetch("satisfied") == true

        session = state.fetch(:session)
        episode = {
          session_id: session.fetch("session_id"),
          task: state.fetch(:task),
          plan_digest: state[:accepted_plan] ? state.fetch(:accepted_plan).fetch("plan_digest") : "sha256:none",
          completed_at: Time.now.to_i,
          scopes: {
            "tenant" => @memory.tenant,
            "user" => memory_owner,
            "project" => "session",
            "session" => session.fetch("session_id")
          },
          sensitivity: :internal,
          decisions: state.fetch(:plan_versions, []).last(3).map { |record| record.fetch("plan_id") },
          corrections: [],
          observed_outcome: {
            "outcome" => verification.fetch("answer"),
            "independently_observed" => true,
            "confidence" => 0.9
          }
        }
        @memory.admission.admit_episode(episode:, owner: memory_owner)
      rescue StandardError
        # Memory writes never fail the session: the episode is evidence, not a
        # gate.
        nil
      end

      # --- helpers -------------------------------------------------------------

      private

      def model_call(context, stage:, system:, prompt:, call_index:)
        EffectDispatcher.run(
          context:,
          operation: "model.generate.#{stage}",
          safety: model_call_safety,
          call_index:,
          request: {"stage" => stage.to_s, "system" => system, "prompt" => prompt},
          actor: "tamoz.agent.session"
        ) { {"output" => String(@model.generate(stage:, system:, prompt:))} }
          .then { |outcome| unwrap_model(outcome) }
      end

      def unwrap_model(outcome)
        return outcome unless outcome.status == :succeeded

        value = outcome.value
        text = value.is_a?(Hash) ? value.fetch("output") : String(value)
        outcome.with(value: text)
      end

      def dispatch(context, intent, step)
        tool = intent.fetch("tool")
        # D-8 Fix A (RC-2): execute the RESOLVED arguments. The digest bound at
        # build_intent is re-injected here from the committed intent, so the bytes
        # executed are the bytes approved (and `verify_intent_before_state!` above
        # re-proves the workspace still matches before `prepare_patch`'s equality
        # check runs as the second binding).
        arguments = resolved_execution_arguments(intent, step)
        safety = intent.fetch("safety").to_sym
        reconciler =
          if safety == :reconcilable
            lambda do
              EffectDispatcher.reconcile_filesystem(
                toolbox:,
                intent:,
                receipt: {"output" => reconciled_receipt(intent)}
              )
            end
          end

        EffectDispatcher.run(
          context:,
          operation: intent.fetch("operation"),
          safety:,
          call_index: 0,
          request: {
            "tool" => tool,
            "arguments" => Deliberation.canonical(arguments),
            "plan_digest" => intent.fetch("plan_digest")
          },
          actor: "tamoz.agent.session",
          reconcile: reconciler
        ) do
          verify_intent_before_state!(intent)
          # P10 §3: an MCP capability executes through the caller-supplied
          # executor *inside* the ordinary effect journal, so exactly-once is the
          # journal's, exactly as for a local tool (invariant 21). The source's
          # executor raises the agent ToolError taxonomy; the journal maps
          # repairable rejections to evidence and everything else propagates.
          result = if mcp_tool?(tool)
                     mcp.execute(context, tool, arguments)
                   else
                     toolbox.execute(tool, arguments)
                   end
          if result.is_a?(CheckReceipt)
            {
              "output" => result.to_s,
              "check" => {
                "name" => result.name,
                "outcome" => result.outcome,
                "passed" => result.passed?,
                "failure_signature" => result.failure_signature
              }
            }
          else
            {"output" => String(result)}
          end
        end
      end

      # The committed intent, not the live workspace, is the authority. If the observed
      # before-state no longer matches what the operator approved, fail closed rather
      # than execute against bytes nobody reviewed.
      def verify_intent_before_state!(intent)
        return unless intent.key?("before_state")

        observed = EffectDispatcher.observe(toolbox.root.join(intent.fetch("path")))
        return if observed.fetch("state") == intent.fetch("before_state")

        raise ToolPolicyError,
              "workspace no longer matches the approved before state for " \
              "#{intent.fetch("path")}"
      end

      def reconciled_receipt(intent)
        case intent.fetch("tool")
        when "apply_patch"
          <<~TEXT.chomp
            Applied #{intent.fetch("path")}
            before_sha256: #{intent.fetch("before_state")}
            after_sha256: #{intent.fetch("after_digest")}
            reconciled: after state proven on disk
          TEXT
        else
          <<~TEXT.chomp
            Created #{intent.fetch("path")}
            mode: #{format("%04o", intent.fetch("after_mode"))}
            sha256: #{intent.fetch("after_digest")}
            reconciled: after state proven on disk
          TEXT
        end
      end

      def build_intent(step, accepted, arguments)
        tool = step.fetch("tool")
        fields = {
          step_id: step.fetch("id"),
          plan_id: accepted.fetch("plan_id"),
          plan_digest: accepted.fetch("plan_digest"),
          tool:,
          operation: "tool.#{tool}",
          safety: tool_safety(tool, arguments).to_s,
          arguments_digest: SessionRecords.digest(Deliberation.canonical(arguments))
        }
        effect_intent = if mcp_tool?(tool)
                          mcp.effect_intent(tool, arguments)
                        else
                          toolbox.effect_intent(tool, arguments)
                        end
        effect_intent.each do |key, value|
          fields[key.to_sym] = value
        end
        fields[:check_name] = arguments.fetch("name") if tool == "run_check"
        SessionRecords.build("effect_intent", **fields)
      end

      # D-8 Fix A (RC-2): single resolution of an absent mutation digest, at the
      # step-gate boundary. apply_patch digests come from observation of the current
      # bytes; create_file digests are content-derived (`hexdigest(content)`, no
      # observation — the file does not exist yet). A present digest is never
      # touched, so the stale-digest refusal stays live.
      def resolved_effect_arguments(arguments, tool)
        return arguments unless %w[apply_patch create_file].include?(tool)
        return arguments if arguments.key?("expected_sha256")

        case tool
        when "apply_patch"
          observed = EffectDispatcher.observe(toolbox.root.join(arguments.fetch("path")))
          arguments.merge("expected_sha256" => observed.fetch("state"))
        when "create_file"
          arguments.merge("expected_sha256" => Digest::SHA256.hexdigest(arguments.fetch("content")))
        end
      end

      # Re-injects the digest committed in the effect intent into the arguments that
      # actually reach execution. The intent carries `before_state` (the observed
      # digest) for apply_patch and `after_digest` (the content digest) for
      # create_file, so the executed arguments always match the approved state even
      # though the plan's own arguments carry no digest.
      def resolved_execution_arguments(intent, step)
        tool = intent.fetch("tool")
        arguments = step.fetch("arguments")
        return arguments unless %w[apply_patch create_file].include?(tool)
        return arguments if arguments.key?("expected_sha256")

        digest =
          case tool
          when "apply_patch" then intent.fetch("before_state")
          when "create_file" then intent.fetch("after_digest")
          else raise ToolError, "unreachable resolved execution arguments"
          end
        arguments.merge("expected_sha256" => digest)
      end

      def tool_safety(tool, arguments)
        return mcp.read_only?(tool) ? :read_only : :unsafe if mcp_tool?(tool)

        case tool
        when "apply_patch", "create_file" then :reconcilable
        when "run_check" then toolbox.check_safety(arguments.fetch("name"))
        else :read_only
        end
      end

      # --- MCP capability surface glue (P10 §3) --------------------------------
      #
      # Every tool-facing decision routes to the caller-supplied source when the
      # step names an MCP capability; otherwise the toolbox keeps the decision.
      # The source never widens the toolbox — the two surfaces are merged only in
      # the planning prompt and the structural review, and only by name.

      def mcp_tool?(tool)
        !!(mcp && mcp.name?(tool))
      end

      # P10 §3 planning surface: merge the source-qualified MCP capability names
      # with their catalog descriptions (compile-bounded and control-stripped;
      # re-stripped at render so no server text enters the prompt unscrubbed).
      # A session without an MCP source renders byte-identically to before.
      def mcp_planning_surface(allowed)
        return {} unless mcp

        allowed.filter_map do |name|
          next unless mcp.name?(name)

          descriptor = mcp.descriptor_for(name)
          snapshot = mcp.catalogs[descriptor.source_id]
          entry = snapshot && snapshot.entries.find { |candidate| candidate.name == descriptor.name }
          description = entry && entry.description
          next if description.nil? || description.empty?

          [name, prompt_safe(description)]
        end.to_h.freeze
      end

      def prompt_safe(value)
        text = String(value)
        unless text.valid_encoding?
          text = text.encode("UTF-8", invalid: :replace, undef: :replace)
        end
        text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      end

      def allowed_tool_names(phase)
        base = phase == :discovery ? toolbox.read_only_names : toolbox.names
        return base unless mcp

        extra = phase == :discovery ? mcp.read_only_names : mcp.names
        (base + extra).uniq
      end

      def approval_required?(tool)
        mcp_tool?(tool) ? mcp.approval_required?(tool) : toolbox.approval_required?(tool)
      end

      def maximum_effect_output_bytes(tool)
        mcp_tool?(tool) ? mcp.maximum_effect_output_bytes(tool) : toolbox.maximum_effect_output_bytes(tool)
      end

      def preview_for(tool, arguments)
        mcp_tool?(tool) ? mcp.preview(tool, arguments) : toolbox.preview(tool, arguments)
      end

      def find_intent(state, accepted, step)
        intent = state.fetch(:effect_intents).reverse.find do |record|
          record.fetch("plan_id") == accepted.fetch("plan_id") &&
            record.fetch("step_id") == step.fetch("id")
        end
        raise ToolError, "no committed effect intent for step #{step.fetch("id")}" unless intent

        intent
      end

      def observation_payload(record)
        payload = {
          "phase" => record.fetch("phase"),
          "repair_attempt" => record.fetch("repair_attempt"),
          "step_id" => record.fetch("step_id"),
          "tool" => record["tool"],
          "output" => record.fetch("output")
        }
        payload["check"] = record.fetch("check") if record.key?("check")
        payload["failure"] = record.fetch("failure") if record.key?("failure")
        payload
      end

      def observation_bytes(state)
        state.fetch(:observations).sum { |record| record.fetch("output").bytesize }
      end

      # Invariant 17: an invalid-argument tool rejection is a typed result, not a
      # propagating failure. It becomes one observation carrying the exact reason, which
      # the repair planner reads as evidence, plus a `failure` record the evaluator uses
      # to enter the bounded repair loop. Nothing was mutated: `apply_patch` and
      # `create_file` complete their whole preflight before any write.
      def tool_failure_update(state, step:, tool:, error_class:, reason:, effect_receipt: nil)
        phase = state.fetch(:phase)
        failure = {
          "kind" => "tool_error",
          "tool" => String(tool),
          "error_class" => String(error_class),
          "reason" => String(reason),
          "failure_signature" => tool_failure_signature(
            tool:,
            reason:,
            arguments: step.fetch("arguments")
          )
        }
        update = {
          step_cursor: state.fetch(:step_cursor) + 1,
          next_node: "evaluate",
          observations: [
            SessionRecords.build(
              "observation",
              phase:,
              repair_attempt: state.fetch(:repair_attempt),
              step_id: step.fetch("id"),
              tool: String(tool),
              output: tool_failure_output(tool, reason),
              failure:
            )
          ]
        }
        update[:effect_receipts] = [effect_receipt] if effect_receipt
        update
      end

      def tool_failure_output(tool, reason)
        <<~TEXT.chomp
          Tool #{tool} was rejected: #{reason}
          The workspace was not changed. Re-read the target with read_file and use its
          exact current bytes and digest before proposing a different action.
        TEXT
      end

      # A check's signature digests its rich output, so identical evidence means the
      # world did not change. A tool rejection's reason is coarse: "patch text was not
      # found" is byte-identical for two completely different wrong `before` strings.
      # The faithful analogue of "the evidence I got" therefore includes the arguments
      # that were rejected. An identical retry still matches here, and is in any case
      # already refused by the repeated-action-signature stop one layer earlier.
      def tool_failure_signature(tool:, reason:, arguments:)
        Digest::SHA256.hexdigest(
          JSON.generate(
            "kind" => "tool_error",
            "tool" => String(tool),
            "reason" => String(reason),
            "arguments_digest" => SessionRecords.digest(Deliberation.canonical(arguments))
          )
        )
      end

      def repairable_outcome?(outcome)
        error = outcome.error
        error.is_a?(Hash) && error["repairable"] == true
      end

      def tool_error_class(outcome)
        error = outcome.error
        return "Tamoz::Agent::ToolError" unless error.is_a?(Hash)

        String(error["class"] || "Tamoz::Agent::ToolError")
      end

      # Only the action and repair phases own a repair budget. Discovery and read-only
      # keep the rejection as evidence and continue with the next planned step.
      def current_pass_tool_failure(state)
        phase = state.fetch(:phase)
        return nil unless %w[action repair].include?(phase)

        attempt = state.fetch(:repair_attempt)
        record = state.fetch(:observations).reverse.find do |entry|
          entry.key?("failure") &&
            entry.fetch("phase") == phase &&
            entry.fetch("repair_attempt") == attempt
        end
        record&.fetch("failure")
      end

      # Only checks from the current phase pass decide routing. A failed check from an
      # earlier repair attempt must not re-trigger a repair.
      def current_pass_check(state)
        phase = state.fetch(:phase)
        attempt = state.fetch(:repair_attempt)
        record = state.fetch(:observations).reverse.find do |entry|
          entry.key?("check") &&
            entry.fetch("phase") == phase &&
            entry.fetch("repair_attempt") == attempt
        end
        record&.fetch("check")
      end

      def failed_check(state, check)
        bounded_repair(state, check.fetch("failure_signature"), repeated_reason: "repeated_failure")
      end

      # The single P2 repair loop. Failed configured checks and repairable tool
      # rejections share one `repair_attempt` counter and one `seen_failure_signatures`
      # channel, so the total repair work a session may do is bounded exactly as before
      # this path existed.
      def bounded_repair(state, signature, repeated_reason:)
        repair_attempt = state.fetch(:repair_attempt)
        if state.fetch(:seen_failure_signatures).include?(signature)
          return {next_node: "verify", terminal_reason: repeated_reason}
        end
        if repair_attempt >= max_repair_attempts
          return {
            next_node: "verify",
            terminal_reason: "repair_attempts_exhausted",
            seen_failure_signatures: [signature]
          }
        end

        {
          next_node: "deliberate",
          phase: "repair",
          repair_attempt: repair_attempt + 1,
          step_cursor: 0,
          seen_failure_signatures: [signature]
        }
      end

      def last_semantic_review(state, accepted)
        record = state.fetch(:plan_reviews).reverse.find do |entry|
          entry.fetch("plan_id") == accepted.fetch("plan_id") &&
            entry.fetch("layer") == "semantic"
        end
        return {} unless record

        {
          "decision" => record.fetch("decision"),
          "issues" => record.fetch("issues"),
          "rationale" => record.fetch("rationale", "")
        }
      end

      def planning_context_for(state, phase)
        context = {}
        if %i[action repair].include?(phase)
          prior_plans = state.fetch(:plan_versions).filter_map do |record|
            record.fetch("plan") if %w[action repair].include?(record.fetch("phase"))
          end
          prior_reviews = state.fetch(:plan_reviews).filter_map do |record|
            next unless record.fetch("layer") == "semantic"

            {
              "decision" => record.fetch("decision"),
              "issues" => record.fetch("issues"),
              "rationale" => record.fetch("rationale", "")
            }
          end
          context = {
            "prior_action_plans" => prior_plans,
            "prior_action_reviews" => prior_reviews,
            "prior_action_signatures" => state.fetch(:seen_action_signatures).sort,
            "prior_failure_signatures" => state.fetch(:seen_failure_signatures).sort
          }
        end

        # P11-W / DR-1 (C5): the promoted Wisdom snapshot is injected as a
        # delimited, findable block; `behavior_snapshot_digest` hashes exactly
        # these canonical bytes, so resume's region comparison is well-posed.
        if (snapshot = state[:session] && state[:session]["behavior_snapshot"])
          context["behavior_snapshot"] = {
            "marker" => Memory::BehaviorTransition::SNAPSHOT_MARKERS,
            "content" => snapshot
          }
        end

        # P11 (scope item 7): automatic injection into the planning context.
        # Experience is NEVER automatic; Knowledge/Wisdom only, bounded by
        # MemoryLimits, sensitive records never injected. A memory-free session
        # (or one without the memory_epoch snapshot) injects nothing and the
        # prompt stays byte-identical.
        if @memory && %i[action repair].include?(phase) &&
           (state[:session] && state[:session]["memory_epoch"]).is_a?(Hash)
          caller = memory_caller(state)
          recall = @memory.retrieval.recall(
            caller:,
            query: {terms: [state.fetch(:task)]},
            automatic: true
          )
          unless recall.records.empty?
            context["memory"] = recall.records.map do |record|
              {
                "memory_id" => record.memory_id,
                "record_version" => record.record_version,
                "layer" => record.layer.to_s,
                "class" => record.klass.to_s,
                "statement" => record.statement
              }
            end
          end
        end
        context
      end

      # P11: the per-session retrieval caller. Scopes are the session's own
      # tenant/user/project (the session memory is scoped to the session).
      def memory_caller(state)
        @memory.caller(
          user: memory_owner,
          project: "session",
          sensitivity: :internal,
          compatibility: {"graph_version" => "1", "behavior_version" => behavior_version(nil)}
        )
      end

      # P11: the authenticated owner of the session's memory writes. Defaults
      # to "session"; a caller may override via Session#memory_owner.
      def memory_owner
        @memory_owner || "session"
      end

      def accept_plan(state, plan:, plan_id:, plan_digest:, plan_hash:, phase:, plans:, reviews:, ambiguity:)
        base = {
          plan_versions: new_records(state, :plan_versions, plans, "plan_id"),
          plan_reviews: new_records(state, :plan_reviews, reviews, "review_id"),
          provider_ambiguity: ambiguity
        }
        if %i[action repair].include?(phase)
          signature = Deliberation.action_signature(plan, toolbox:)
          if state.fetch(:seen_action_signatures).include?(signature)
            return base.merge(next_node: "verify", terminal_reason: "repeated_action")
          end

          base[:seen_action_signatures] = [signature]
        end
        base.merge(
          accepted_plan: SessionRecords.build(
            "accepted_plan",
            plan_id:,
            plan_digest:,
            phase: phase.to_s,
            plan: plan_hash,
            accepted_at_ms: 0
          ),
          step_cursor: 0,
          next_node: "step_gate"
        )
      end

      def plan_rejected(state, plans:, reviews:, ambiguity:, phase:, repair_attempt:)
        if phase == :repair && repair_attempt.positive?
          return {
            plan_versions: new_records(state, :plan_versions, plans, "plan_id"),
            plan_reviews: new_records(state, :plan_reviews, reviews, "review_id"),
            provider_ambiguity: ambiguity,
            next_node: "verify",
            terminal_reason: "repair_plan_rejected"
          }
        end

        raise PlanRejectedError, plan_rejected_message(reviews)
      end

      # D-8 Fix C (RC-3): the disclosed message is bounded to the last attempt's
      # STRUCTURAL-layer issues — Tamoz-generated validation text, first three issues,
      # further clamped by `Error.disclosable_message` at the safe_message boundary.
      # Semantic feedback is model-authored and protocol feedback quotes the provider
      # payload, so either yields the generic phrase; neither is ever interpolated.
      def plan_rejected_message(reviews)
        prefix = "no plan passed review after #{max_plan_attempts} attempts"
        last = reviews.last
        unless last && last.fetch("layer") == "structural" && last.fetch("decision") == "revise"
          return "#{prefix}: the plan did not pass review; the last feedback is not discloseable"
        end

        "#{prefix}: #{last.fetch("issues").first(3).join("; ")}"
      end

      def clarify_update(state, context:, plan_id:, plan_digest:, review:, phase:, repair_attempt:, plans:, reviews:, ambiguity:)
        descriptor = {
          "kind" => "clarify",
          "session_id" => state.fetch(:session).fetch("session_id"),
          "plan_id" => plan_id,
          "plan_digest" => plan_digest,
          "question" => review.fetch("issues").join("\n"),
          "context" => {"phase" => phase.to_s, "repair_attempt" => repair_attempt}
        }
        answer = Tamoz.interrupt(descriptor, context)
        clarify_step_id = "clarify.#{plan_id}"
        if state.fetch(:observations).any? { |record| record.fetch("step_id") == clarify_step_id }
          raise Tamoz::InvalidUpdateError,
                "clarify interrupt for #{plan_id} has already been answered"
        end
        unless answer.is_a?(String) && !answer.strip.empty?
          raise Tamoz::InvalidUpdateError, "clarify answer must be a non-empty string"
        end

        {
          plan_versions: new_records(state, :plan_versions, plans, "plan_id"),
          plan_reviews: new_records(state, :plan_reviews, reviews, "review_id"),
          provider_ambiguity: ambiguity,
          observations: [
            SessionRecords.build(
              "observation",
              phase: phase.to_s,
              repair_attempt:,
              step_id: clarify_step_id,
              output: answer.strip,
              tool: "clarify"
            )
          ],
          next_node: "deliberate"
        }
      end

      def new_records(state, channel, records, id_key)
        existing = state.fetch(channel).map { |record| record.fetch(id_key) }
        records.reject { |record| existing.include?(record.fetch(id_key)) }
      end

      def blocked_update(outcome, reason, step_id: nil, operation: nil)
        {
          next_node: "terminal",
          terminal_reason: "effect_unknown",
          blocked: SessionRecords.build(
            "blocked",
            reason:,
            effect_key: outcome.effect_key,
            operation: String(operation || "model.generate"),
            step_id:,
            actions: [
              "inspect the operation and its target",
              "record the true outcome with Session#resolve_effect",
              "then continue the session"
            ]
          )
        }
      end

      def tool_error_message(outcome)
        error = outcome.error
        return "tool effect failed" unless error.is_a?(Hash)

        String(error["message"] || "tool effect failed")
      end
    end
  end
end
