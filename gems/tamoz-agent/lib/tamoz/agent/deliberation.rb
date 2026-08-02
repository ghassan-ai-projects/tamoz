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

      VERIFY_SYSTEM = <<~TEXT.freeze
        You are Tamoz's final verification stage. Use only the supplied task, accepted plan,
        and tool observations. Do not invent evidence. Return only JSON with answer (string),
        satisfied (boolean), and evidence (array of strings). If evidence is insufficient,
        set satisfied to false and say exactly what remains unknown.
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

      def planning_prompt(task, phase, allowed_tools, evidence, feedback, planning_context, toolbox:)
        phase_instruction = if phase == :discovery
                              "Gather only the evidence needed to prepare a later action plan. Do not mutate or run commands."
                            elsif phase == :action
                              "Use the discovery evidence to propose the exact bounded actions and verification checks."
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
          "available_tools" => toolbox.descriptions.slice(*allowed_tools),
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

      def review_prompt(task, plan, phase:, evidence:, planning_context:)
        review_input = {
          "task" => task,
          "phase" => phase.to_s,
          "evidence" => evidence,
          "plan" => plan.to_h
        }
        review_input["planning_context"] = planning_context unless planning_context.empty?
        JSON.pretty_generate(review_input)
      end

      def verification_prompt(task, plan, review, observations, verification_context:)
        verification_input = {
          "task" => task,
          "accepted_plan" => plan.to_h,
          "review" => review,
          "observations" => observations
        }
        unless verification_context.empty?
          verification_input["verification_context"] = verification_context
        end
        JSON.pretty_generate(verification_input)
      end

      def structural_issues(plan, phase:, allowed_tools:, toolbox:, mcp: nil)
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
              # P10 §3: an MCP capability is validated by the caller-supplied
              # source (no I/O), so a schema-invalid MCP step is a plan-time
              # repairable rejection exactly like a bad local argument. A bare,
              # non-source-qualified name never reaches this branch: it is not in
              # `allowed_tools`, so the "unavailable tool" issue above already
              # rejected it (P10 §10.2 malicious-tool-name row).
              if mcp && mcp.name?(step.tool)
                mcp.validate(step.tool, step.arguments)
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

      # D-8 Fix B (RC-4), scoped heuristic. `path` and `expected_sha256` are never
      # legitimate `<`+`>` carriers, so they get the containment check ON TOP of the
      # universal rules; every other string argument is checked for the whole-string
      # `\A<.*>\z` shape and the cross-step reference phrases. Nested values
      # (compound replacement entries) are walked with the same rules.
      def placeholder_arguments?(arguments)
        arguments.any? do |key, value|
          case value
          when String
            contained = PLACEHOLDER_CONTAINMENT_KEYS.include?(String(key)) &&
              value.include?("<") && value.include?(">")
            universal = value.match?(PLACEHOLDER_WHOLE_STRING) ||
              PLACEHOLDER_REFERENCE_PHRASES.any? { |phrase| value.include?(phrase) }
            contained || universal
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
        Digest::SHA256.hexdigest(JSON.generate(canonical(actions)))
      end

      def canonicalize_apply_patch_arguments(arguments)
        return arguments unless arguments.is_a?(Hash) && arguments["replacements"].is_a?(Array)

        sorted = arguments["replacements"].each_with_index.sort_by { |entry, _index| entry["before"] }.map(&:first)
        arguments.merge("replacements" => sorted)
      end

      def canonical(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), normalized|
            normalized[String(key)] = canonical(entry)
          end.sort.to_h
        when Array
          value.map { |entry| canonical(entry) }
        else
          value
        end
      end
    end
  end
end
