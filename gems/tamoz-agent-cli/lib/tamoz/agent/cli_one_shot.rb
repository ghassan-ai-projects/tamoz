# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      # `tamoz TASK`: one in-memory run.
      class OneShot
        def initialize(out:, err:, input:, events:, models:)
          @out = out
          @err = err
          @input = input
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

        def routing(options)
          if options[:experimental_routing] then :experimental
          elsif options[:shadow_routing] then :shadow
          else :legacy
          end
        end

        def approve(tool:, **)
          @err.print "Approve #{tool} [a/approve, d/deny]? "
          @err.flush
          Tamoz::Approval::Answer.parse(@input.gets.to_s)
        end
      end
    end
  end
end
