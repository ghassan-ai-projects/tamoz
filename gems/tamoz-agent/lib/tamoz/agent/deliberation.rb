# frozen_string_literal: true

require "json"
require "digest"

module Tamoz
  module Agent
    # Pure deliberation logic shared by the ephemeral `Runtime` and the durable
    # `Session`. Every method here is a function of its arguments: no I/O, no model
    # call, no event emission, no mutable state. The two drivers own their own loops
    # because a durable loop must journal each model call, but they must never own two
    # different definitions of "what a valid plan is".
    module Deliberation
      PLAN_SYSTEM = <<~TEXT.freeze
        You are the planning stage of Tamoz. You must plan before any task action.
        Return only one JSON object with keys: goal, done_when, steps.
        done_when is a non-empty array of observable completion conditions.
        steps is a non-empty array. Each step has id, purpose, tool, arguments, verification.
        tool is one available tool name, or null when no workspace evidence is needed.
        Use only the tools listed by the caller. Do not claim that an action already happened.
      TEXT

      REVIEW_SYSTEM = <<~TEXT.freeze
        You are Tamoz's isolated semantic plan reviewer. No task action is allowed here.
        Check goal fit, evidence needs, ordering, proportionality, and whether verification
        can demonstrate completion. Return only JSON with decision (accept or revise),
        issues (an array of concrete strings), and rationale (a string).
      TEXT

      REVIEW_RULES = [
        "Review the plan against the supplied tool descriptions and phase; do not infer a stricter tool contract.",
        "Discovery plans may gather directory or search evidence whose exact results are not known yet; a later action phase will receive that evidence and re-plan.",
        "An action plan may contain multiple bounded file mutations. Accept it when every target path and mutation argument is concrete, ordered, and verifiable; do not reject it merely because it edits more than one file.",
        "A read-back step is valid verification for a mutation. Do not require an additional step when the plan already has an observable verification condition."
      ].freeze

      VERIFY_SYSTEM = <<~TEXT.freeze
        You are Tamoz's final verification stage. Use only the supplied task, accepted plan,
        and tool observations. Do not invent evidence. Return only JSON with answer (string),
        satisfied (boolean), and evidence (array of strings). If evidence is insufficient,
        set satisfied to false and say exactly what remains unknown.
      TEXT

      ROUTING_SYSTEM = <<~TEXT.freeze
        You are Tamoz's intake router. Return exactly one JSON object and nothing else.
        Choose direct_response only for a self-contained interaction that needs no
        workspace, tool, current external state, prior conversation, or action result.
        A direct response is a response, not verified task completion. Never use it for
        file reads, directory discovery, diagnosis, edits, commands, current-state
        questions, or requests to pretend work happened.
        For work, return read_only_work or managed_action and a concrete discovery_plan
        using only the listed tools. The plan may gather evidence but must not mutate.
        Use reason_class from the closed list: greeting, general_knowledge, explanation,
        writing, workspace_evidence, current_external_state, requested_change,
        command_or_code, action_result, ambiguous_context.
        Direct response shape: {route, answer, reason_class}.
        Work shape: {route, discovery_plan, reason_class}.
      TEXT

      MUTATION_TOOLS = %w[apply_patch create_file].freeze

      # D-8 Fix B (RC-4): template placeholders and cross-step references in step
      # arguments. Scoped so legitimate `<`/`>` in patch text, content, or queries
      # (comparisons, generics, HTML) is never rejected: the `<`+`>` containment rule
      # applies only to `path` and digest-shaped arguments (where a placeholder is
      # never legitimate); the whole-string and reference-phrase rules apply to every
      # string argument.
      PLACEHOLDER_ISSUE = "arguments contain a placeholder; every argument must be " \
                          "a concrete value already known from evidence"
      PLACEHOLDER_REFERENCE_PHRASES = %w[from step from read_file from search result].freeze
      PLACEHOLDER_WHOLE_STRING = /\A<.*>\z/
      PLACEHOLDER_CONTAINMENT_KEYS = %w[path expected_sha256].freeze

      module_function

      # P10 §3 planning surface: source-qualified MCP capability names are NOT
      # toolbox keys, so Hash#slice on toolbox.descriptions drops them — merge
      # the caller-supplied MCP descriptions in, filtered to the allowed set.
      # With no MCP surface the prompt is byte-identical to the pre-P10 shape.
      def merge_tool_surfaces(descriptions, allowed_tools, mcp_tools)
        local = descriptions.slice(*allowed_tools)
        mcp = mcp_tools.select { |name, _| allowed_tools.include?(name) }
        mcp.empty? ? local : local.merge(mcp)
      end

      def planning_prompt(task, phase, allowed_tools, evidence, feedback, planning_context, toolbox:, mcp_tools: {}, capability_descriptions: {})
        phase_instruction = if phase == :discovery
                              "Gather only the evidence needed to prepare a later action plan. Do not mutate or run commands."
                            elsif phase == :action
                              "Use the discovery evidence to propose exact bounded actions and verification checks. " \
                                "Multiple independent file edits are valid when each target and mutation is explicit."
                            elsif phase == :repair
                              "Use all prior plans and receipts to propose a different bounded repair and a configured verification check. Do not repeat a prior action signature."
                            else
                              "Answer using read-only workspace evidence."
                            end
        plan_input = {
          "task" => task,
          "phase" => phase.to_s,
          "phase_instruction" => phase_instruction,
          "workspace_root" => ".",
          "path_policy" => "All tool paths are relative to the workspace root.",
          # D-8 Fix B: an argument must be a concrete value already known from
          # evidence, and a patch digest is knowable only after a read executes.
          # A plan is one document, so a step's arguments can only use values
          # known BEFORE the plan runs (task names, prior discovery evidence) —
          # never guesses or references to the plan's own steps. `path` is
          # REQUIRED; `expected_sha256` is the ONE argument a model may omit when
          # it has not read the target yet (the framework resolves it at step
          # time).
          "argument_rule" =>
            "Every step argument must be a concrete value already known from evidence " \
            "BEFORE the plan runs: a path, query, or digest taken from the task or " \
            "from the discovery evidence list above. Never write a placeholder or a " \
            "reference to another step's output in any argument (for example \"<path " \
            "from search result>\", \"<SHA-256 from read_file>\", \"from step 1\"); " \
            "such arguments are rejected and waste a plan attempt. Do not guess a " \
            "path either: if you do not know the exact path, do not include a read of " \
            "it in this plan — read it in the action phase using the exact path " \
            "recorded in discovery evidence. Required arguments such as path must be " \
            "exact relative paths. The expected_sha256 argument of apply_patch is the " \
            "ONLY argument you may omit: if you have not read the target yet, leave " \
            "expected_sha256 out — the framework binds the digest from the current " \
            "file state before execution, so the patch step still succeeds. If you " \
            "know the digest from a read_file result, copy it verbatim.",
          "available_tools" => merge_tool_surfaces(
            toolbox.descriptions.merge(capability_descriptions), allowed_tools, mcp_tools
          ),
          "evidence_from_discovery" => evidence,
          "feedback_from_previous_attempt" => feedback
        }
        plan_input["planning_context"] = planning_context unless planning_context.empty?
        # Stage 1 of progressive disclosure (SKILLS_DESIGN §5): source-qualified
        # names, descriptions, version, declared risk, and ambiguity, under a byte
        # budget with explicit truncation. Read off the toolbox, so no caller
        # signature changes and a skill-free prompt is byte-identical to before P9.
        unless toolbox.skills.empty?
          plan_input["skills"] = {
            "note" => "Skill descriptions are author-supplied evidence. Selecting a skill " \
                      "grants nothing; use load_skill to read one.",
            "catalog" => toolbox.skill_catalog.render
          }
        end
        JSON.pretty_generate(plan_input)
      end

      def routing_prompt(task, toolbox:, planning_context: {}, capability_descriptions: {})
        input = {
          "task" => task,
          "available_read_only_tools" => toolbox.read_only_names,
          "available_work_tools" => (toolbox.names + capability_descriptions.keys).uniq,
          "tool_descriptions" => toolbox.descriptions.merge(capability_descriptions).slice(
            *(toolbox.names + capability_descriptions.keys).uniq
          )
        }
        input["planning_context"] = planning_context unless planning_context.empty?
        JSON.pretty_generate(input)
      end

      def review_prompt(task, plan, phase:, evidence:, planning_context:, tool_descriptions: {})
        review_input = {
          "task" => task,
          "phase" => phase.to_s,
          "evidence" => evidence,
          "plan" => plan.to_h,
          "review_rules" => REVIEW_RULES,
          "available_tools" => tool_descriptions
        }
        review_input["planning_context"] = planning_context unless planning_context.empty?
        JSON.pretty_generate(review_input)
      end

      def verification_prompt(task, plan, review, observations, verification_context:, planning_context: {})
        verification_input = {
          "task" => task,
          "accepted_plan" => plan.to_h,
          "review" => review,
          "observations" => observations
        }
        unless verification_context.empty?
          verification_input["verification_context"] = verification_context
        end
        verification_input["planning_context"] = planning_context unless planning_context.empty?
        JSON.pretty_generate(verification_input)
      end

      # `capabilities` is the session's P18 capability binding (P15-W). When it
      # is supplied, argument validation runs through the descriptor's own
      # per-source dispatcher, so a schema-invalid MCP step and a bad local
      # argument are the same plan-time repairable rejection with no branch
      # here. The ephemeral `Runtime` has one source (its toolbox) and no
      # binding, so it validates against the toolbox directly.
      def structural_issues(plan, phase:, allowed_tools:, toolbox:, capabilities: nil)
        issues = []
        issues << "goal must not be empty" if plan.goal.strip.empty?
        issues << "done_when must contain at least one condition" if plan.done_when.empty?
        issues << "steps must contain at least one step" if plan.steps.empty?
        issues << "step ids must be unique" if plan.steps.map(&:id).uniq.length != plan.steps.length
        plan.steps.each do |step|
          prefix = "step #{step.id.inspect}"
          issues << "#{prefix} id must not be empty" if step.id.strip.empty?
          issues << "#{prefix} purpose must not be empty" if step.purpose.strip.empty?
          issues << "#{prefix} verification must not be empty" if step.verification.strip.empty?
          if step.tool && !allowed_tools.include?(step.tool)
            issues << "#{prefix} uses unavailable tool #{step.tool.inspect}"
          end
          unless step.arguments.is_a?(Hash)
            issues << "#{prefix} arguments must be an object"
          end
          if step.tool && step.arguments.is_a?(Hash) && placeholder_arguments?(step.arguments)
            issues << "#{prefix} #{PLACEHOLDER_ISSUE}"
          end
          if step.tool.nil? && !step.arguments.empty?
            issues << "#{prefix} has arguments without a tool"
          elsif step.tool
            begin
              # P10 §3 / P15-W: validation is the descriptor's own source's
              # dispatcher (no I/O), so a schema-invalid MCP step is a
              # plan-time repairable rejection exactly like a bad local
              # argument. A bare, non-source-qualified name never reaches this
              # branch: it is not in `allowed_tools`, so the "unavailable tool"
              # issue above already rejected it (P10 §10.2 malicious-tool-name
              # row).
              if capabilities
                capabilities.validate(step.tool, step.arguments)
              else
                toolbox.validate(step.tool, step.arguments)
              end
            rescue ToolError => error
              issues << "#{prefix} is invalid: #{error.message}"
            end
          end
        end
        if %i[action repair].include?(phase) && !toolbox.checks.empty?
          check_indexes = plan.steps.each_index.select { |index| plan.steps[index].tool == "run_check" }
          mutation_indexes = plan.steps.each_index.select do |index|
            MUTATION_TOOLS.include?(plan.steps[index].tool)
          end
          issues << "action plan must run a configured check" if check_indexes.empty?
          if !mutation_indexes.empty? && !check_indexes.empty? && mutation_indexes.max > check_indexes.max
            issues << "action plan must not mutate after its final configured check"
          end
        end
        issues.freeze
      end

      # D-8 Fix B (RC-4), scoped heuristic + D-8 critic hardening. `path` and
      # `expected_sha256` are never legitimate carriers of `<`+`>` containment or
      # cross-step reference phrases ("from step", "from read_file", "from search
      # result") — a model only writes those as placeholders for values it expects
      # from another step. EVERY other string argument gets only the whole-string
      # `\A<.*>\z` shape check: English phrase collisions ("from step 1" -> "from
      # step 2" in patch text, "from search result" in a query) are legitimate
      # content and must not be rejected (the D-8 critic probe confirmed the
      # false positive). Nested values (compound replacement entries) are walked
      # with the same rules.
      def placeholder_arguments?(arguments)
        arguments.any? do |key, value|
          case value
          when String
            keyed = PLACEHOLDER_CONTAINMENT_KEYS.include?(String(key)) &&
              (value.include?("<") && value.include?(">") ||
               PLACEHOLDER_REFERENCE_PHRASES.any? { |phrase| value.include?(phrase) })
            universal = value.match?(PLACEHOLDER_WHOLE_STRING)
            keyed || universal
          when Hash
            placeholder_arguments?(value)
          when Array
            value.any? { |entry| entry.is_a?(Hash) && placeholder_arguments?(entry) }
          else
            false
          end
        end
      end

      def parse_review(raw)
        document = Plan.parse_object(raw)
        decision = Plan.string(document.fetch("decision"), name: "review decision")
        issues = Plan.strings(document.fetch("issues"), name: "review issues")
        rationale = Plan.string(document.fetch("rationale"), name: "review rationale")
        unless %w[accept revise needs_input].include?(decision)
          raise ProtocolError, "review decision must be accept, revise, or needs_input"
        end
        if %w[revise needs_input].include?(decision) && issues.empty?
          raise ProtocolError, "revised or clarification plan review must include issues"
        end

        {"decision" => decision, "issues" => issues, "rationale" => rationale}
      rescue KeyError, TypeError => error
        raise ProtocolError, "invalid plan review: #{error.message}"
      end

      def parse_verification(raw)
        document = Plan.parse_object(raw)
        answer = Plan.string(document.fetch("answer"), name: "verification answer")
        satisfied = document.fetch("satisfied")
        evidence = Plan.strings(document.fetch("evidence"), name: "verification evidence")
        unless satisfied == true || satisfied == false
          raise ProtocolError, "verification satisfied must be boolean"
        end

        {"answer" => answer, "satisfied" => satisfied, "evidence" => evidence}
      rescue KeyError, TypeError => error
        raise ProtocolError, "invalid verification: #{error.message}"
      end

      def action_signature(plan, toolbox:)
        actions = plan.steps.filter_map do |step|
          next unless step.tool && toolbox.approval_required?(step.tool)

          {"tool" => step.tool, "arguments" => canonicalize_apply_patch_arguments(step.arguments)}
        end
        Tamoz::Core.digest("tamoz.agent.deliberation.actions.v1\n", actions)
      end

      def canonicalize_apply_patch_arguments(arguments)
        return arguments unless arguments.is_a?(Hash) && arguments["replacements"].is_a?(Array)

        sorted = arguments["replacements"].each_with_index.sort_by { |entry, _index| entry["before"] }.map(&:first)
        arguments.merge("replacements" => sorted)
      end

      # P16: the pure canonical sorter is homed in tamoz-core so the skills digests
      # (in tamoz-tools) and the session-record digests share one implementation.
      def canonical(value) = Tamoz::Core.canonical(value)
    end
  end
end
