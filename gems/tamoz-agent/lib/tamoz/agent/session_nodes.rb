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

      attr_reader :toolbox, :max_plan_attempts, :max_repair_attempts, :model_call_safety, :profile

      def initialize(
        model:,
        toolbox:,
        max_plan_attempts:,
        max_repair_attempts:,
        model_call_safety:,
        profile: nil
      )
        @model = model
        @toolbox = toolbox
        @max_plan_attempts = max_plan_attempts
        @max_repair_attempts = max_repair_attempts
        @model_call_safety = model_call_safety
        @profile = profile
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

        {
          task:,
          phase: toolbox.action_capable? ? "discovery" : "read_only",
          repair_attempt: 0,
          step_cursor: 0,
          next_node: "deliberate",
          session: SessionRecords.build(
            "session",
            session_id: String(context.thread_id),
            task:,
            task_digest: Digest::SHA256.hexdigest(task),
            root: toolbox.root.to_s,
            graph_version: GRAPH_VERSION,
            behavior_version: BEHAVIOR_VERSION,
            tool_catalog_digest: toolbox.catalog_digest,
            created_at_ms: 0,
            **profile_binding,
            **skill_binding
          )
        }
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

      # P8: a profile-bound session pins its authority in the session record. The
      # constructor has already verified the toolbox matches the profile surface
      # (§5.2), so intake records the identity plus the exact authority snapshot
      # (§5.4) that a later resume replays instead of re-reading the profile file.
      # Editing the file afterwards cannot reach this record.
      def profile_binding
        return {} unless profile

        {
          profile_id: profile.profile_id,
          profile_digest: profile.canonical_digest,
          profile_authority: profile.authority_snapshot
        }
      end

      def deliberate(state, context)
        # A cancel sentinel routed by intake must reach terminal without any model I/O.
        if state.fetch(:next_node) == "terminal" && state.fetch(:terminal_reason) == "cancelled_by_user"
          return {}
        end

        phase = state.fetch(:phase).to_sym
        repair_attempt = state.fetch(:repair_attempt)
        task = state.fetch(:task)
        evidence = state.fetch(:observations).map { |record| observation_payload(record) }
        allowed_tools = phase == :discovery ? toolbox.read_only_names : toolbox.names
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
              toolbox:
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
          plans << SessionRecords.build(
            "plan",
            plan_id:,
            phase: phase.to_s,
            attempt:,
            plan: plan_hash,
            plan_digest:
          )

          structural = Deliberation.structural_issues(
            plan,
            phase:,
            allowed_tools:,
            toolbox:
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
          intent = build_intent(step, accepted)
          unless toolbox.approval_required?(tool)
            return {next_node: "step_execute", effect_intents: [intent]}
          end

          budget = toolbox.maximum_effect_output_bytes(tool)
          if observation_bytes(state) + budget > MAX_OBSERVATION_BYTES
            raise ToolError, "insufficient observation budget for #{tool}"
          end

          preview = toolbox.preview(tool, step.fetch("arguments"))
        rescue ToolArgumentError => error
          return tool_failure_update(
            state,
            step:,
            tool:,
            error_class: error.class.name,
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
          "arguments" => step.fetch("arguments"),
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
        arguments = step.fetch("arguments")
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
          result = toolbox.execute(tool, arguments)
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

      def build_intent(step, accepted)
        tool = step.fetch("tool")
        arguments = step.fetch("arguments")
        fields = {
          step_id: step.fetch("id"),
          plan_id: accepted.fetch("plan_id"),
          plan_digest: accepted.fetch("plan_digest"),
          tool:,
          operation: "tool.#{tool}",
          safety: tool_safety(tool, arguments).to_s,
          arguments_digest: SessionRecords.digest(Deliberation.canonical(arguments))
        }
        toolbox.effect_intent(tool, arguments).each do |key, value|
          fields[key.to_sym] = value
        end
        fields[:check_name] = arguments.fetch("name") if tool == "run_check"
        SessionRecords.build("effect_intent", **fields)
      end

      def tool_safety(tool, arguments)
        case tool
        when "apply_patch", "create_file" then :reconcilable
        when "run_check" then toolbox.check_safety(arguments.fetch("name"))
        else :read_only
        end
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
        return {} unless %i[action repair].include?(phase)

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
        {
          "prior_action_plans" => prior_plans,
          "prior_action_reviews" => prior_reviews,
          "prior_action_signatures" => state.fetch(:seen_action_signatures).sort,
          "prior_failure_signatures" => state.fetch(:seen_failure_signatures).sort
        }
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

        raise PlanRejectedError, "no plan passed review after #{max_plan_attempts} attempts"
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
