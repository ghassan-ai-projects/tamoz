# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      # Answers a paused turn's interrupts: from `--answer`, or by asking the
      # operator, and records an approval in the engine that asked for it.
      class InterruptAnswers
        EFFECT_RESOLUTIONS = {
          'fixed' => :succeeded, 'approve' => :succeeded, 'ok' => :succeeded, 'succeeded' => :succeeded,
          'yes' => :succeeded, 'skipped' => :abandoned, 'deny' => :abandoned, 'no' => :abandoned,
          'abandoned' => :abandoned, 'failed' => :failed, 'unknown' => :unknown, '?' => :unknown
        }.freeze

        # The words an operator types are a stable user-facing contract.
        def self.parse(kind, raw)
          answer = raw.to_s.strip.downcase
          case kind
          when 'approve_tool' then approved?(answer, raw)
          when 'clarify' then answer.empty? ? nil : raw.to_s.strip
          when 'resolve_effect'
            EFFECT_RESOLUTIONS.fetch(answer) { raise ArgumentError, "invalid resolve_effect answer: #{raw.inspect}" }
          else raw
          end
        end

        def self.approved?(answer, raw)
          parsed = Tamoz::Approval::Answer.parse(answer)
          raise ArgumentError, "invalid approve_tool answer: #{raw.inspect}" if parsed.nil?

          parsed == :approve
        end
        private_class_method :approved?

        def initialize(operator, options)
          @err = operator.err
          @prompts = operator.prompts
          @approvals = operator.approvals
          @options = options
        end

        # Answers every interrupt and records the decisions this process's engine
        # owns; nil when an interrupt is left unanswered.
        def resolve(view, resume_options)
          scripted = resume_options[:answer]
          view.interrupts.each_with_object({}) do |interrupt, answers|
            value = answer_for(interrupt.descriptor, scripted)
            return nil if value.nil?

            resolve_decision(interrupt.descriptor, value, interactive: !@options[:non_interactive] && scripted.nil?)
            (answers[interrupt.task_id] ||= {})[interrupt.call_index] = value
          end
        end

        private

        def answer_for(descriptor, scripted)
          render_prompt(descriptor) if (scripted || @options[:non_interactive]) && !@options[:json]
          return self.class.parse(descriptor['kind'], scripted) if scripted
          return nil if @options[:non_interactive]

          ask(descriptor)
        end

        # Shown when no prompt will ask; an interactive prompt shows the descriptor itself.
        def render_prompt(descriptor)
          case descriptor['kind']
          when 'approve_tool'
            PromptAdapter.approval_banner(@err, descriptor['tool'], descriptor['preview'])
          when 'clarify'
            @err.puts descriptor['question']
          end
        end

        def ask(descriptor)
          case descriptor['kind']
          when 'approve_tool' then @prompts.approve_tool(descriptor)
          when 'clarify' then @prompts.clarify(descriptor)
          else @prompts.interrupt(descriptor)
          end
        end

        # Only the engine that asked records the answer; another process's
        # decision resolves there.
        def resolve_decision(descriptor, value, interactive:)
          asked = descriptor['decision']
          return unless descriptor['kind'] == 'approve_tool' && asked

          decision_id = asked.fetch('id')
          return unless @approvals.holds_decision?(decision_id)

          @approvals.resolve(decision_id:, answer: value ? :approve : :deny,
                             scope: grant_scope(descriptor, value, interactive))
        end

        def grant_scope(descriptor, value, interactive)
          return nil unless value

          offered = Array(descriptor.dig('decision', 'grant_scopes')).include?('session')
          interactive && offered && @prompts.remember_for_session(descriptor) ? :session : :once
        end
      end
    end
  end
end
