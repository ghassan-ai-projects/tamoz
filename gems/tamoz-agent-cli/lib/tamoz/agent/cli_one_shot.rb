# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      # A task run once, in memory, with no durable thread: `tamoz TASK`.
      class OneShot
        def initialize(out:, err:, input:, events:, models:)
          @out = out
          @prompts = PromptAdapter.new(input:, err:)
          @events = events
          @models = models
        end

        def run(task, options)
          runtime = Tamoz::Agent.build(
            model: @models.build(options), root: options[:root], allow_changes: options[:allow_changes],
            checks: options[:checks], skills: SkillsOptions.new(options).snapshot(options[:root]),
            ask: method(:approve), routing: routing(options)
          )
          result = runtime.run(task) { |event| @events.render(event, json: options[:json]) }
          print_result(result) unless options[:json]
          result.exit_status
        end

        private

        def print_result(result)
          @out.puts
          @out.puts result.answer
          label = if result.responded?
                    'Response: not verified task completion'
                  else
                    "Verification: #{result.satisfied ? 'satisfied' : 'not satisfied'}"
                  end
          @out.puts("\n#{label}")
        end

        # Only the one-shot path honors --shadow-routing (unification is an owner decision).
        def routing(options)
          if options[:experimental_routing] then :experimental
          elsif options[:shadow_routing] then :shadow
          else :legacy
          end
        end

        def approve(tool:, **)
          @prompts.approve(tool)
        end
      end
    end
  end
end
