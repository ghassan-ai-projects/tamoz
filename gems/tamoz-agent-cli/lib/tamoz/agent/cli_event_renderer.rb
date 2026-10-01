# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    class CLI
      # Shows the operator what a run is doing: one stderr line per runtime event,
      # or one JSON envelope per event on stdout in `--json` mode.
      # :reek:FeatureEnvy :reek:TooManyStatements -- a renderer reads the event it
      # was given and prints one line per field.
      class EventRenderer
        ENVELOPE_SCHEMA = 1
        LINES = {
          task_started: ->(_) { 'Working...' },
          route_selected: ->(data) { "Route: #{data.fetch('route')}" },
          route_fallback: ->(_) { 'Route fallback: continuing with the standard workflow.' },
          route_shadow: ->(data) { "Route shadow: #{data.fetch('route')} (standard workflow retained)" },
          plan_reviewed: ->(data) { "Review (#{data.fetch('layer')}): #{data.fetch('decision')}" },
          tool_started: ->(data) { "Running #{data.fetch('tool')}..." }
        }.freeze

        def initialize(out:, err:)
          @out = out
          @err = err
        end

        def render(event, json:)
          if json
            emit(event.type.to_s, event.data)
            return
          end

          render_line(event.type, event.data)
        end

        # The machine contract for every JSON-mode line. StreamPart-backed events
        # carry their full identity (run_id, task_id, sequence, emitted_at);
        # synthetic local events carry none of those keys rather than nulls.
        def emit(type, data, part = nil)
          envelope = {
            'schema' => ENVELOPE_SCHEMA,
            'type' => type,
            'data' => data,
            'task_state' => data['task_state'],
            'delivery_state' => data['delivery_state']
          }
          envelope.merge!(part_identity(part)) if part
          @out.puts JSON.generate(envelope)
        end

        private

        def part_identity(part)
          { 'run_id' => part.run_id, 'task_id' => part.task_id, 'sequence' => part.sequence,
            'emitted_at' => part.emitted_at }
        end

        def render_line(type, data)
          line = LINES[type]
          return @err.puts(line.call(data)) if line

          case type
          when :plan_drafted then render_plan(data)
          when :approval_requested then render_approval_request(data)
          when :healing_assessment then render_healing_assessment(data)
          end
        end

        def render_plan(data)
          @err.puts "Plan #{data.fetch('attempt')} (#{data.fetch('phase')}):"
          data.fetch('plan').fetch('steps').each do |step|
            tool = step.fetch('tool') ? " [#{step.fetch('tool')}]" : ''
            @err.puts "  - #{step.fetch('purpose')}#{tool}"
          end
        end

        def render_approval_request(data)
          return unless data['verdict'] == 'ask'

          PromptAdapter.approval_banner(@err, data.fetch('tool'), data.fetch('preview'))
        end

        def render_healing_assessment(data)
          category = data.fetch('category')
          if data.fetch('remediable')
            @err.puts "Self-healing: this failure (#{category}) is remediable by " \
                      "rule #{data.fetch('rule_id')} [#{data.fetch('action_family')}] — staged, not executed."
          else
            never_mutate = data['never_mutate_class']
            reason = never_mutate ? "never-mutate class #{never_mutate}" : 'no matching rule'
            @err.puts "Self-healing: this failure (#{category}) is not auto-remediable (#{reason}); escalating."
          end
        end
      end
    end
  end
end
