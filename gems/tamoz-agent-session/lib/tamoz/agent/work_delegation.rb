# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Runs one bounded child graph and projects its durable result into a parent tool result.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:IrresponsibleModule
    # :reek:LongParameterList :reek:TooManyStatements :reek:UtilityFunction
    # The child output is one result contract; splitting its validation, rendering and trace would loosen that contract.
    class WorkDelegation
      MAX_BRIEF_BYTES = 4096
      MAX_ANSWER_BYTES = 4096
      MAX_READ_PATHS = 20
      Projection = Data.define(:status, :reads, :answer, :truncated)

      def initialize(services:, work:)
        @services = services
        @work = work
      end

      def call(state, context, call)
        child, refusal = admitted_child(state, call.arguments)
        return error(refusal) if refusal

        brief = call.arguments.fetch('brief')
        output, duration_ms = run_child(child, brief, context)
        result, finished = result_for(child, output, duration_ms)
        digest = "sha256:#{Digest::SHA256.hexdigest(brief)}"
        started = { 'event' => 'subagent_started', 'role' => child.role.name, 'brief_digest' => digest,
                    'execution_id' => output.fetch(:work_execution_id) }
        WorkTools::Outcome.new(text: result, update: { work_trace: [started, finished] })
      end

      private

      def run_child(child, brief, context)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output = child.app.call({ task: brief }, context)
        [output, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).to_i]
      end

      def admitted_child(state, arguments)
        child = @services.configuration.subagent_apps[arguments['role']]
        return [nil, 'unknown subagent role'] unless child

        refusal = invalid_brief(arguments['brief'])
        return [nil, refusal] if refusal

        cap = Harness::SubagentRoles.shipped.max_per_turn
        return [nil, "subagent limit reached (#{cap} per turn)"] if started_count(state) >= cap

        [child, nil]
      end

      def error(message) = WorkTools::Outcome.new(text: "Error: #{message}", update: {})

      def invalid_brief(brief)
        return 'the brief must be a non-empty string' unless brief.is_a?(String) && !brief.strip.empty?
        return "brief exceeds #{MAX_BRIEF_BYTES} bytes" if brief.bytesize > MAX_BRIEF_BYTES
        return 'brief contains a credential-shaped value' if Core.secret_shaped?(brief)

        nil
      end

      def started_count(state)
        state.fetch(:work_trace).count { |event| event['event'] == 'subagent_started' }
      end

      def result_for(child, output, duration_ms)
        answer = @work.scrub(String(output.dig(:verification, 'answer') || ''))
        answer_text, truncated = answer_part(answer)
        projection = Projection.new(status: status_for(output.fetch(:terminal_reason)),
                                    reads: Array(output[:work_observations]).to_h.keys.sort,
                                    answer: answer_text, truncated:)
        [render(child, output, projection), finished_event(child, output, projection, duration_ms)]
      end

      def render(child, output, projection)
        probes = output.fetch(:work_entries).filter_map do |entry|
          entry['name'] if entry['kind'] == 'tool_result' && entry['source'] == 'probe'
        end.uniq.sort
        ["Subagent #{child.role.name}: #{projection.status}", read_line(projection.reads),
         "Probes answered: #{probes.empty? ? 'none' : probes.join(', ')}",
         cost_line(output),
         "Answer (truncated: #{projection.truncated ? 'yes' : 'no'}):", projection.answer].join("\n")
      end

      def cost_line(output)
        "Cost: #{model_calls(output)} model calls, " \
          "#{output.fetch(:work_signatures).length} tool calls, " \
          "#{tokens(output, 'prompt_tokens')} prompt tokens, " \
          "#{tokens(output, 'completion_tokens')} completion tokens"
      end

      def finished_event(child, output, projection, duration_ms)
        { 'event' => 'subagent_finished', 'role' => child.role.name, 'status' => projection.status,
          'model_calls' => model_calls(output), 'tool_calls' => output.fetch(:work_signatures).length,
          'prompt_tokens' => tokens(output, 'prompt_tokens'),
          'completion_tokens' => tokens(output, 'completion_tokens'),
          'duration_ms' => duration_ms, 'read_count' => projection.reads.length, 'truncated' => projection.truncated }
      end

      def status_for(reason)
        case reason
        when 'answered', 'done', 'verified_no_changes' then 'done'
        when 'reported', 'handed_off', 'cancelled_by_user' then reason
        when 'work_failed', /\Amodel_/ then 'failed'
        else 'unknown'
        end
      end

      def read_line(paths)
        shown = paths.first(MAX_READ_PATHS)
        extra = paths.length - shown.length
        suffix = extra.positive? ? " (+#{extra} more)" : ''
        "Read: #{shown.empty? ? 'none' : shown.join(', ')}#{suffix}"
      end

      def answer_part(answer)
        return [answer, false] if answer.bytesize <= MAX_ANSWER_BYTES

        digest = "sha256:#{Digest::SHA256.hexdigest(answer)}"
        @work.store.retain(digest:, bytes: answer, media_type: 'text/plain')
        ["Full answer: artifact:#{digest}\n#{answer.byteslice(0, MAX_ANSWER_BYTES - 100).scrub}", true]
      end

      def tokens(output, key)
        output.fetch(:work_trace).sum do |event|
          field = key == 'completion_tokens' ? 'output_tokens' : key
          event['event'] == 'request' ? event.fetch('usage', {}).to_h.fetch(field, 0) : 0
        end
      end

      def model_calls(output) = output.fetch(:work_trace).count { |event| event['event'] == 'request' }
    end
  end
end
