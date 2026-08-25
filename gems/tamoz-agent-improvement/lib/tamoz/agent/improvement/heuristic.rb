# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Improvement
      # P12-I1 (plan §7): the ONE bounded planning heuristic candidate. It is
      # deliberately the narrowest useful shape: "before a step that uses
      # `subject_tool` on a target, plan a `precursor_tool` step on that same
      # target first". That is a planning/routing/verification heuristic in the
      # plan §7 sense and nothing else — it adds no tool, no root, no
      # credential, no approval, and no authority.
      #
      # Hard bounds (invariant 28, plan §9 "no code, prompt, evaluator,
      # permission, or policy rewrite"):
      #
      # * `apply` only ever INSERTS a read-only precursor step; it never
      #   removes, reorders, or rewrites an existing step, and never changes a
      #   step's tool or arguments. A heuristic that could delete a step could
      #   delete a verification step.
      # * the precursor tool must be read-only. A heuristic that could inject a
      #   MUTATION into a plan is a capability change, which is a human-gated
      #   class, not a heuristic.
      # * the rendered snapshot is bounded by
      #   `Memory::BehaviorTransition::MAX_BEHAVIOR_SNAPSHOT_BYTES`.
      class Heuristic < Data.define(
        :heuristic_id, :surface, :precursor_tool, :subject_tool,
        :support, :trials, :confidence, :statement, :generator_principal
      )
        DIGEST_DOMAIN = "tamoz.agent.improvement.heuristic.v1\n"
        SURFACES = %i[planning routing verification].freeze
        # The read-only tool set a heuristic may insert. `apply_patch`,
        # `create_file`, and `run_check` are NOT here: a plan mutation is a
        # capability change with its own gate, never a generated heuristic.
        INSERTABLE_TOOLS = %w[read_file list_directory search_text].freeze
        MAX_STATEMENT_BYTES = 512
        MAX_INSERTIONS = 8

        def initialize(
          heuristic_id:, surface:, precursor_tool:, subject_tool:,
          support:, trials:, confidence:, statement:, generator_principal:
        )
          super
        end

        def assert_bounded!
          unless SURFACES.include?(surface)
            raise ImprovementPolicyError, "heuristic surface must be one of #{SURFACES.join("/")}"
          end
          unless INSERTABLE_TOOLS.include?(String(precursor_tool))
            raise ImprovementPolicyError,
                  "heuristic precursor tool #{precursor_tool.inspect} is not read-only; " \
                  "a generated heuristic may never insert a mutation"
          end
          if String(subject_tool).empty?
            raise ImprovementPolicyError, "heuristic requires a subject tool"
          end
          if statement.to_s.bytesize > MAX_STATEMENT_BYTES
            raise ImprovementPolicyError, "heuristic statement exceeds #{MAX_STATEMENT_BYTES} bytes"
          end
          unless trials.to_i.positive? && support.to_i.positive? && support.to_i <= trials.to_i
            raise ImprovementPolicyError, "heuristic support/trials are not a valid ratio"
          end
          if Memory::Surface.secret_shaped?(statement.to_s)
            raise ImprovementPolicyError, "heuristic statement carries secret-shaped content"
          end
          self
        end

        # The bounded immutable behavior snapshot that the transition pins and
        # the planning prompt injects as a delimited region (DR-1 §4 C5). This
        # is the ONLY thing a promoted heuristic puts in front of the model.
        def snapshot
          {
            "kind" => "heuristic",
            "heuristic_id" => heuristic_id,
            "surface" => surface.to_s,
            "statement" => statement
          }
        end

        # Content identity: the same heuristic derived twice from the same
        # trajectories has the same digest, so a repeated promotion attempt is
        # idempotent at the transition-row level (`transition_id =
        # sha256(kind + candidate_digest)`). Support counts ARE part of the
        # identity: a heuristic with different evidence is a different
        # candidate.
        def digest
          Tamoz::Core.digest(DIGEST_DOMAIN, to_h)
        end

        def to_h
          {
            "heuristic_id" => heuristic_id,
            "surface" => surface.to_s,
            "precursor_tool" => precursor_tool,
            "subject_tool" => subject_tool,
            "support" => support,
            "trials" => trials,
            "confidence" => confidence,
            "statement" => statement,
            "generator_principal" => generator_principal
          }
        end

        # Apply the heuristic to a plan step list. INSERT-ONLY: for every step
        # that uses `subject_tool` on a target with no earlier step reading that
        # same target with `precursor_tool`, a precursor step is inserted
        # immediately before it. Existing steps cross through untouched and in
        # order, which is what makes this reversible: dropping the heuristic
        # restores exactly the input list.
        def apply(steps)
          return steps unless steps.is_a?(Array)

          read_targets = []
          inserted = 0
          result = []
          steps.each do |step|
            unless step.is_a?(Hash)
              result << step
              next
            end

            tool = String(step["tool"])
            target = target_of(step)
            if tool == String(subject_tool) &&
               target && !read_targets.include?(target) && inserted < MAX_INSERTIONS
              inserted += 1
              result << precursor_step_for(step, target, inserted)
              read_targets << target
            end
            read_targets << target if tool == String(precursor_tool) && target
            result << step
          end
          result
        end

        private

        def target_of(step)
          arguments = step["arguments"]
          return nil unless arguments.is_a?(Hash)

          value = arguments["path"]
          value.is_a?(String) && !value.empty? ? value : nil
        end

        def precursor_step_for(step, target, ordinal)
          {
            "id" => "#{step["id"]}.heuristic.#{ordinal}",
            "purpose" => "read #{target} before changing it (#{heuristic_id})",
            "tool" => String(precursor_tool),
            "arguments" => {"path" => target},
            "verification" => "the current content of #{target} is on the record",
            "origin" => heuristic_id
          }
        end
      end
    end
  end
end
