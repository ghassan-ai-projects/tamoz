# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # One finished child as its parent reads it: status, the paths its ledger read, the probes it answered, its cost and
    # its answer cut to a byte budget (the whole answer kept for recall_output). Built from the child's durable output,
    # never from its prose; no wall clock, so a re-run gate node renders the same text.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy
    # Every line is a projection of the child's output record.
    class SubagentReport
      MAX_READ_PATHS = 20

      attr_reader :role, :output

      def initialize(role:, output:, store:, scrub:)
        @role = role
        @output = output
        @store = store
        @answer = scrub.call(String(output.dig(:verification, 'answer') || ''))
      end

      def status
        case output.fetch(:terminal_reason)
        when 'answered', 'done', 'verified_no_changes' then 'done'
        when 'reported', 'handed_off', 'cancelled_by_user' then output.fetch(:terminal_reason)
        when 'work_failed', /\Amodel_/ then 'failed'
        else 'unknown'
        end
      end

      def reads = Hash(output[:work_observations]).select { |_, seen| seen['read'] }.keys.sort

      def truncated?(budget) = @answer.bytesize > budget

      def render(budget)
        ["Subagent #{role}: #{status}", read_line, "Probes answered: #{probes}", cost_line,
         "Answer (truncated: #{truncated?(budget) ? 'yes' : 'no'}):", answer_within(budget)].join("\n")
      end

      def finished_event(duration_ms, budget)
        { 'event' => 'subagent_finished', 'role' => role, 'status' => status, 'model_calls' => model_calls,
          'tool_calls' => tool_calls, 'prompt_tokens' => tokens('prompt_tokens'),
          'completion_tokens' => tokens('output_tokens'), 'duration_ms' => duration_ms, 'read_count' => reads.length,
          'truncated' => truncated?(budget) }
      end

      private

      def probes
        names = output.fetch(:work_entries).filter_map do |entry|
          entry['name'] if entry['kind'] == 'tool_result' && entry['source'] == 'probe'
        end
        names.empty? ? 'none' : names.uniq.sort.join(', ')
      end

      def read_line
        paths = reads
        extra = paths.length - MAX_READ_PATHS
        listed = paths.empty? ? 'none' : paths.first(MAX_READ_PATHS).join(', ')
        "Read: #{listed}#{" (+#{extra} more)" if extra.positive?}"
      end

      def cost_line
        "Cost: #{model_calls} model calls, #{tool_calls} tool calls, #{tokens('prompt_tokens')} prompt tokens, " \
          "#{tokens('output_tokens')} completion tokens"
      end

      def answer_within(budget)
        return @answer unless truncated?(budget)

        digest = "sha256:#{Digest::SHA256.hexdigest(@answer)}"
        @store.retain(digest:, bytes: @answer, media_type: 'text/plain')
        "Full answer: artifact:#{digest}\n#{@answer.byteslice(0, [budget - 100, 0].max).scrub}"
      end

      def requests = output.fetch(:work_trace).select { |event| event['event'] == 'request' }
      def model_calls = requests.length
      def tool_calls = output.fetch(:work_signatures).length
      def tokens(field) = requests.sum { |event| event['usage'].to_h.fetch(field, 0) }
    end
  end
end
