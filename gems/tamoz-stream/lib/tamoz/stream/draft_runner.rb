# frozen_string_literal: true

require 'tamoz/core'
require 'tamoz/stream/gen'
require 'tamoz/stream/draft_reply'
require 'tamoz/stream/durable_terminal'
require 'tamoz/stream/budget_limits'
require 'tamoz/stream/episode_stream'

module Tamoz
  module Stream
    # Runs one DraftPlaybookRule request durably on the episode graph's draft route.
    class DraftRunner
      MAX_CASES = 20
      # "draft.<id>" must fit the durable store's 128-byte request id.
      MAX_ID_BYTES = 120
      UNKNOWN_CODE = 'unknown'
      Identity = Struct.new(:episode_id, :attempt_id, :fence)
      private_constant :Identity

      def initialize(durable_runner:, tenant:, model_policy:)
        @durable_runner = durable_runner
        @tenant = String(tenant).dup.freeze
        @model_policy = String(model_policy).dup.freeze
      end

      def run(request)
        payload = payload_for(request)
        stream = EpisodeStream.new(Identity.new(request.draft_id, 'draft', 1))
        result = @durable_runner.deliver(
          payload, thread: thread_id(request), request_id: thread_id(request), operation: :turn,
                   delivery: :queue, namespace: [@tenant], context: context_for(request, EpisodeStreamAdapter.new(stream))
        )
        [answer(request, result, stream)]
      end

      private

      def thread_id(request) = "draft.#{request.draft_id}"

      def answer(request, result, stream)
        state = DurableTerminal.state(@durable_runner, thread_id: thread_id(request), namespace: [@tenant], result:)
        usage = EpisodeStreamAdapter.cumulative_usage(Array(state[:model_receipts]))
        return DraftReply.event(state.fetch(:draft), key: request.key, usage:) if result.status == :completed

        diagnostic = stream.events.filter_map(&:diagnostic).last ||
                     V1::Diagnostic.new(code: DurableTerminal.reason_code(result) || 'draft_failed',
                                        message: 'the draft ended without an answer')
        V1::DraftEvent.new(diagnostic:, usage:)
      end

      def context_for(request, emitter)
        id = thread_id(request)
        Tamoz::Context.new(
          run_id: id, execution_id: id, request_id: id, interrupt_mode: :non_interactive, emitter:,
          deadline: deadline(request.budget&.wall_time), cancellation: Tamoz::CancellationToken.new
        )
      end

      def deadline(wall_time)
        return nil unless wall_time

        Process.clock_gettime(Process::CLOCK_MONOTONIC) + wall_time.seconds + (wall_time.nanos / 1e9)
      end

      def payload_for(request)
        admit!(request)
        {
          'episode' => {
            'episode_id' => request.draft_id, 'attempt_id' => 'draft', 'fence' => 1, 'kind' => 'draft',
            'tenant_id' => @tenant
          },
          'wire' => { 'model_policy' => @model_policy, 'budget' => budget(request.budget), 'draft' => draft(request) }
        }
      end

      def draft(request)
        key = request.key
        {
          'key' => { 'diagnosis_code' => key.diagnosis_code, 'intent' => key.intent, 'preset' => key.preset },
          'cases' => request.cases.map { |entry| case_entry(entry) },
          'current_rules' => request.current_rules.map do |rule|
            { 'rule_id' => rule.rule_id, 'version' => rule.version, 'when' => rule.when, 'mode' => rule.mode }
          end,
          'allowed_features' => request.allowed_features.to_a
        }
      end

      # Go may encode a feature as -0 or an integer past 2^53; CEL reads every number as a double, so do we.
      def case_entry(entry)
        features = JSON.parse(entry.features_json)
        refuse("case #{entry.episode_id} features are not an object") unless features.is_a?(Hash)

        {
          'episode_id' => entry.episode_id, 'diagnosis_code' => entry.diagnosis_code, 'intent' => entry.intent,
          'preset' => entry.preset, 'verdict' => entry.verdict, 'summary' => entry.summary,
          'features' => features.transform_values { |value| value.is_a?(Numeric) ? value.to_f + 0.0 : value }
        }
      rescue JSON::ParserError
        refuse("case #{entry.episode_id} features are not JSON")
      end

      def budget(wire)
        return nil unless wire

        {
          'max_model_calls' => BudgetLimits.positive_int_or_nil(wire.model_calls),
          'max_input_tokens' => BudgetLimits.positive_int_or_nil(wire.input_tokens),
          'max_output_tokens' => BudgetLimits.positive_int_or_nil(wire.output_tokens)
        }
      end

      def admit!(request)
        refuse('the draft belongs to another tenant') unless request.tenant_id == @tenant
        id = request.draft_id
        refuse('draft_id is required') if id.empty?
        refuse("draft_id must be at most #{MAX_ID_BYTES} bytes with no control characters") if
          id.bytesize > MAX_ID_BYTES || id.match?(/[\x00-\x1F\x7F]/)
        admit_key!(request.key)
        refuse("a draft needs 1 to #{MAX_CASES} cases") unless request.cases.length.between?(1, MAX_CASES)
        ids = request.cases.map(&:episode_id)
        refuse('every case needs its own episode_id') if ids.include?('') || ids.uniq.length != ids.length
        admit_budget!(request.budget)
      end

      def admit_key!(key)
        refuse('a draft needs a key with a diagnosis code and an intent') if
          key.nil? || key.diagnosis_code.empty? || key.intent.empty?
        refuse("#{UNKNOWN_CODE} never becomes a rule") if key.diagnosis_code == UNKNOWN_CODE
      end

      def admit_budget!(wire)
        return unless wire

        limits = BudgetLimits
        refuse("wall_time exceeds #{limits::MAX_WALL_TIME_SECONDS}s") if
          wire.wall_time && wire.wall_time.seconds > limits::MAX_WALL_TIME_SECONDS
        refuse("model_calls exceeds #{limits::MAX_MODEL_CALLS}") if wire.model_calls > limits::MAX_MODEL_CALLS
      end

      def refuse(message)
        raise GRPC::InvalidArgument, message
      end

      V1 = Agenticstream::Runtime::V1
      private_constant :V1
    end
  end
end
