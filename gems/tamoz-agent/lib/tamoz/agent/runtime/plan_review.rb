# frozen_string_literal: true

module Tamoz
  module Agent
    class Runtime
      # Bounded plan drafting for one phase: the model drafts a plan, structural
      # policy review adjudicates first, semantic review second, and each layer's
      # feedback feeds the next attempt until max_plan_attempts is exhausted.
      #
      # :nodoc:
      module PlanReview
        private

        def accepted_plan(
          task,
          phase:,
          allowed_tools:,
          evidence:,
          metadata:,
          planning_context:
        )
          event_context = {"phase" => phase.to_s}.merge(metadata)
          feedback = []
          # D-8 Fix C (RC-3): track the last attempt's feedback layer so the
          # PlanRejectedError discloses a bounded summary of STRUCTURAL-layer issues
          # only; semantic (model-authored) and protocol (provider-quoting) feedback
          # yields the generic phrase.
          last_layer = nil
          max_plan_attempts.times do |offset|
            attempt = offset + 1
            raw = model_generate(
              stage: :plan,
              system: PLAN_SYSTEM,
              prompt: planning_prompt(
                task,
                phase,
                allowed_tools,
                evidence,
                feedback,
                planning_context
              )
            )
            plan = Plan.parse(raw)
            emit(:plan_drafted, event_context.merge("attempt" => attempt, "plan" => plan.to_h)) do |event|
              yield event
            end

            structural_issues = structural_issues(plan, phase:, allowed_tools:)
            emit(
              :plan_reviewed,
              event_context.merge(
                "attempt" => attempt,
                "layer" => "structural",
                "decision" => structural_issues.empty? ? "accept" : "revise",
                "issues" => structural_issues
              )
            ) { |event| yield event }
            unless structural_issues.empty?
              feedback = structural_issues
              last_layer = :structural
              next
            end

            review = semantic_review(task, plan, phase:, evidence:, planning_context:)
            emit(:plan_reviewed, review.merge(event_context).merge("attempt" => attempt, "layer" => "semantic")) do |event|
              yield event
            end
            if review.fetch("decision") == "accept"
              emit(:plan_accepted, event_context.merge("attempt" => attempt, "plan" => plan.to_h)) do |event|
                yield event
              end
              return [plan, Tamoz::Core.deep_freeze(review)]
            end

            feedback = review.fetch("issues")
            last_layer = :semantic
          rescue ProtocolError => e
            feedback = [e.message]
            last_layer = :protocol
            emit(
              :plan_reviewed,
              event_context.merge(
                "attempt" => attempt,
                "layer" => "protocol",
                "decision" => "revise",
                "issues" => feedback
              )
            ) { |event| yield event }
          end

          raise PlanRejectedError, plan_rejected_message(last_layer, feedback)
        end

        # D-8 Fix C (RC-3): bounded structural-only rejection disclosure, mirroring
        # `SessionNodes#plan_rejected_message`. `Error.disclosable_message` clamps and
        # scrubs again at the safe_message boundary.
        def plan_rejected_message(last_layer, feedback)
          prefix = "no plan passed review after #{max_plan_attempts} attempts"
          return "#{prefix}: the plan did not pass review; the last feedback is not discloseable" \
            unless last_layer == :structural

          "#{prefix}: #{feedback.first(3).join("; ")}"
        end

        def structural_issues(plan, phase:, allowed_tools:)
          Deliberation.structural_issues(plan, phase:, allowed_tools:, toolbox:)
        end

        def semantic_review(task, plan, phase:, evidence:, planning_context:)
          raw = model_generate(
            stage: :review,
            system: REVIEW_SYSTEM,
            prompt: Deliberation.review_prompt(
              task,
              plan,
              phase:,
              evidence:,
              planning_context:,
              tool_descriptions: Deliberation.merge_tool_surfaces(
                toolbox.descriptions,
                toolbox.names,
                {}
              )
            )
          )
          Deliberation.parse_review(raw)
        end

        def planning_prompt(task, phase, allowed_tools, evidence, feedback, planning_context)
          Deliberation.planning_prompt(
            task,
            phase,
            allowed_tools,
            evidence,
            feedback,
            planning_context,
            toolbox:
          )
        end
      end
      private_constant :PlanReview
    end
  end
end
