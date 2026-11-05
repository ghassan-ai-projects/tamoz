# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # The verified work of one finished thread, written as the markdown a skill draft starts from.
    module CLISkillTrajectory
      private

      def verified_trajectory(options, thread)
        view = nil
        run_durable(options, thread, read_only: true) { |session, _request_id, _owner_id| view = session.view(thread:) }
        state = view.state
        verification = state[:verification] || {}
        unless state[:terminal_reason] == 'done' && verification['satisfied'] == true
          raise ArgumentError,
                "thread #{thread} did not finish verified (#{state[:terminal_reason]}); " \
                'only verified work becomes a skill'
        end

        Tamoz::Core.scrub_secrets(trajectory_text(state, verification))
      end

      def trajectory_text(state, verification)
        tool_results = Array(state[:work_entries]).select { |entry| entry['kind'] == 'tool_result' }
        tools = tool_results.map { |entry| entry['name'] }
        <<~MARKDOWN
          # Verified trajectory

          ## Task

          #{state[:task]}

          ## Plan

          #{trajectory_plan(state[:work_plan])}

          ## Tools used, in order

          #{bullet_list(tools, empty: '(none)')}

          ## Files changed

          #{bullet_list(Array(state[:work_changes]).uniq)}

          ## Checks

          #{bullet_list(check_lines(state), empty: '(none)')}

          ## Final answer

          #{verification['answer']}
        MARKDOWN
      end

      def trajectory_plan(plan)
        plan ? JSON.pretty_generate(plan) : '(none recorded)'
      end

      def check_lines(state)
        Array(state[:work_checks]).map { |check| "#{check['name']}: #{check['passed'] ? 'passed' : 'failed'}" }
      end

      def bullet_list(lines, empty: '')
        return empty if lines.empty?

        lines.map { |line| "- #{line}" }.join("\n")
      end
    end
  end
end
