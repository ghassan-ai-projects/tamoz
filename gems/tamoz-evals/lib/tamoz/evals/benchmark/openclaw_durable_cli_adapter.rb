# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'stringio'

module Tamoz
  module Evals
    module Benchmark
      # Runs one OpenClaw mission through the operator CLI's durable queue and
      # worker path. The adapter never calls a provider itself: the CLI builds
      # RubyLLMModel and Session, while this class only joins their durable
      # receipt view with the separately recorded observability trace.
      class OpenclawDurableCliAdapter
        TRACE_SOURCE = 'tamoz.observability.journal'
        THREAD_PREFIX = 'openclaw'

        class CredentialUnavailable < Tamoz::Evals::ExecutionError; end
        class TraceUnavailable < Tamoz::Evals::ExecutionError; end

        # rubocop:disable Metrics/ParameterLists -- injected seams keep the production path testable.
        def initialize(runtime_dir:, workspace:, env: ENV.to_h, cli: nil, evidence_reader: nil,
                       routing: :adaptive, run_id: nil)
          @runtime_dir = File.expand_path(String(runtime_dir))
          @workspace = File.expand_path(String(workspace))
          @env = env.to_h.transform_keys(&:to_s)
          @cli = cli || Tamoz::Agent::CLI.method(:run)
          @evidence_reader = evidence_reader || DurableSessionEvidenceReader.new(env: @env, routing:)
          @routing = routing.to_sym
          @run_id = String(run_id || SecureRandom.hex(8))
          validate_inputs!
        end
        # rubocop:enable Metrics/ParameterLists

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one durable mission transaction.
        def call(mission:, run_kind:, provider:, model:)
          raise ArgumentError, 'OpenClaw durable adapter only supports real_provider runs' unless
            run_kind == 'real_provider'

          provider = String(provider)
          model = String(model)
          credential_binding!(provider)
          initialize_runtime!
          thread = thread_id(mission.fetch('id'))
          enqueue!(thread, mission.fetch('goal'), provider:, model:)
          worker!(provider:, model:)
          evidence = @evidence_reader.call(
            runtime_dir: @runtime_dir, thread:, provider:, model:
          )
          trace = trace!(thread)
          receipts = model_receipts(evidence.fetch('effect_receipts'))
          validate_receipts!(receipts)
          independent_trace = independent_trace!(trace, receipts, mission:, thread:)
          durable_mission = durable_mission!(evidence, mission:, thread:)

          {
            'status' => 'ready',
            'provenance' => {
              'run_kind' => 'real_provider',
              'provider' => provider,
              'model' => model,
              'thread_id' => thread,
              'provider_effect_receipts' => receipts,
              'provider_trace_digest' => provider_trace_digest(mission, receipts, independent_trace),
              'independent_trace' => independent_trace
            },
            'metrics' => metrics(evidence, receipts, independent_trace),
            'surface_executions' => surface_executions(provider:, model:),
            'terminal' => terminal_projection(evidence.fetch('terminal')),
            'durable_mission' => durable_mission
          }
        rescue CredentialUnavailable, TraceUnavailable => e
          { 'status' => 'blocked', 'reason' => e.message }
        rescue Tamoz::Evals::ExecutionError => e
          { 'status' => 'blocked', 'reason' => bounded_reason(e.message) }
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        private

        def validate_inputs!
          raise ArgumentError, 'runtime_dir is required' if @runtime_dir.empty?
          raise ArgumentError, 'workspace is required' if @workspace.empty?
          raise ArgumentError, 'cli must respond to call' unless @cli.respond_to?(:call)
          raise ArgumentError, 'evidence_reader must respond to call' unless @evidence_reader.respond_to?(:call)
          raise ArgumentError, 'routing is invalid' unless Tamoz::Agent::Session::ROUTINGS.include?(@routing)
        end

        def credential_binding!(provider)
          key = Tamoz::Agent::RubyLLMModel::ENV_KEYS.fetch(provider.downcase.to_sym) do
            raise CredentialUnavailable, "provider_credential_unavailable:#{provider}"
          end
          return { 'kind' => 'api_key', 'name' => key } unless @env[key].to_s.empty?
          return { 'kind' => 'api_base', 'name' => 'OLLAMA_API_BASE' } if
            provider.casecmp('ollama').zero? && !@env['OLLAMA_API_BASE'].to_s.empty?

          raise CredentialUnavailable, "provider_credential_unavailable:#{key}"
        end

        def initialize_runtime!
          invoke(base_args + ['init', '--workspace', @workspace, '--json'])
          directory = Tamoz::Agent::RuntimeDirectory.resolve(path: @runtime_dir, env: @env)
          return if File.expand_path(directory.workspace_root) == @workspace

          raise Tamoz::Evals::ExecutionError, 'runtime_workspace_mismatch'
        rescue Tamoz::Agent::Error => e
          raise Tamoz::Evals::ExecutionError, "runtime_initialization_failed:#{e.class}"
        end

        def enqueue!(thread, task, provider:, model:)
          document = invoke(
            base_args(provider:, model:) +
            ['queue', 'add', '--task', task, '--thread', thread, '--json']
          )
          return if document.fetch('status') == 'queued' && document.fetch('thread') == thread

          raise Tamoz::Evals::ExecutionError, 'queue_submission_not_accepted'
        end

        def worker!(provider:, model:)
          invoke(base_args(provider:, model:) + ['worker', '--once', '--json'])
        end

        def trace!(thread)
          document = invoke(['--runtime-dir', @runtime_dir, 'trace', thread, '--json'])
          unless document.is_a?(Hash) && document['trace_id'].is_a?(String) &&
                 document['spans'].is_a?(Array)
            raise TraceUnavailable, 'independent_trace_unavailable'
          end

          document
        rescue JSON::ParserError, KeyError, TypeError
          raise TraceUnavailable, 'independent_trace_unavailable'
        end

        def invoke(argv)
          out = StringIO.new
          err = StringIO.new
          status = @cli.call(argv, out:, err:, input: StringIO.new, env: @env)
          unless status.zero?
            raise Tamoz::Evals::ExecutionError, "cli_command_failed:#{argv.drop_while do |arg|
              arg.start_with?('--')
            end.first}"
          end

          parse_json_output(out.string)
        rescue JSON::ParserError
          raise Tamoz::Evals::ExecutionError, 'cli_output_invalid'
        end

        def parse_json_output(output)
          lines = output.each_line.map(&:strip).reject(&:empty?)
          JSON.parse(lines.fetch(-1))
        rescue IndexError, JSON::ParserError
          raise Tamoz::Evals::ExecutionError, 'cli_output_invalid'
        end

        def base_args(provider: nil, model: nil)
          args = ['--runtime-dir', @runtime_dir, '--root', @workspace]
          args += ['--provider', provider, '--model', model] if provider && model
          args << '--adaptive-routing' if @routing == :adaptive
          args
        end

        def thread_id(mission_id)
          digest = Digest::SHA256.hexdigest("#{@run_id}\n#{mission_id}")[0, 24]
          "#{THREAD_PREFIX}.#{digest}"
        end

        def model_receipts(receipts)
          Array(receipts).filter_map do |receipt|
            next unless receipt.is_a?(Hash)
            next unless receipt['operation'].to_s.start_with?('model.generate.')

            receipt.slice('effect_key', 'operation', 'status', 'usage')
          end
        end

        def validate_receipts!(receipts)
          valid = receipts.is_a?(Array) && !receipts.empty? && unique_receipts?(receipts) &&
                  receipts.all? { |receipt| valid_receipt?(receipt) }
          return if valid

          raise Tamoz::Evals::ExecutionError, 'provider_effect_receipt_unavailable'
        end

        def unique_receipts?(receipts)
          keys = receipts.map { |receipt| receipt['effect_key'] }
          keys.uniq == keys
        end

        def valid_receipt?(receipt)
          receipt.is_a?(Hash) && receipt['effect_key'].is_a?(String) &&
            receipt['operation'].to_s.start_with?('model.generate.') &&
            receipt['status'] == 'succeeded'
        end

        def independent_trace!(trace, receipts, mission:, thread:)
          spans = Array(trace.fetch('spans'))
          model_spans = spans.select { |span| span['name'] == 'tamoz.model.call' }
          if trace.fetch('trace_id').to_s.empty? || model_spans.length < receipts.length
            raise TraceUnavailable, 'independent_trace_missing_model_spans'
          end

          {
            'source' => TRACE_SOURCE,
            'run_id' => @run_id,
            'thread_id' => thread,
            'mission_id' => mission.fetch('id'),
            'trace_id' => trace.fetch('trace_id'),
            'trace_digest' => digest(trace),
            'trace' => trace,
            'model_span_count' => model_spans.length
          }
        rescue KeyError, TypeError
          raise TraceUnavailable, 'independent_trace_unavailable'
        end

        def provider_trace_digest(mission, receipts, independent_trace)
          Readiness.provider_trace_digest(
            mission_digest: digest(mission), receipts:, independent_trace:
          )
        end

        def durable_mission!(evidence, mission:, thread:)
          verification = evidence.fetch('verification', {})
          terminal = evidence.fetch('terminal', {})
          valid = evidence['status'].to_s == 'completed' && terminal['satisfied'] == true &&
                  verification['configured_check_passed'] == true
          raise Tamoz::Evals::ExecutionError, 'durable_mission_not_verified' unless valid

          {
            'mission_id' => mission.fetch('id'), 'run_id' => @run_id, 'thread_id' => thread,
            'status' => 'completed', 'satisfied' => true, 'verified' => true
          }
        end

        # rubocop:disable Metrics/AbcSize
        def metrics(evidence, receipts, independent_trace)
          spans = independent_trace.fetch('trace').fetch('spans')
          durations = spans.filter_map { |span| span['duration_ms'] if span['name'] == 'tamoz.model.call' }
          usage = receipts.filter_map { |receipt| receipt['usage'] }.grep(Hash)
          metrics = {
            'model_calls' => receipts.length,
            'model_calls_succeeded' => receipts.count { |receipt| receipt['status'] == 'succeeded' },
            'model_trace_spans' => independent_trace.fetch('model_span_count'),
            'trace_spans' => spans.length,
            'terminal_status' => evidence.fetch('status').to_s
          }
          metrics['model_latency_ms'] = durations.sum unless durations.empty?
          unless usage.empty?
            metrics['provider_tokens'] = usage.sum do |entry|
              entry.fetch('input_tokens', 0).to_i + entry.fetch('output_tokens', 0).to_i
            end
          end
          metrics
        end
        # rubocop:enable Metrics/AbcSize

        def terminal_projection(terminal)
          return {} unless terminal.is_a?(Hash)

          terminal.slice('reason', 'satisfied', 'status')
        end

        def surface_executions(provider:, model:)
          {
            'cli' => {
              'status' => 'executed',
              'provenance' => {
                'surface' => 'cli', 'run_kind' => 'real_provider',
                'provider' => provider, 'model' => model
              }
            },
            'telegram' => {
              'status' => 'unavailable',
              'provenance' => {
                'surface' => 'telegram', 'run_kind' => 'real_provider',
                'provider' => provider, 'model' => model, 'reason' => 'adapter_not_configured'
              }
            }
          }
        end

        def digest(value)
          "sha256:#{Digest::SHA256.hexdigest(Tamoz::Evals::CanonicalJSON.dump(value))}"
        end

        def bounded_reason(message)
          String(message).byteslice(0, 256).to_s
        end
      end

      # Reads durable session evidence after the worker has finished. It opens
      # the same runtime database as the worker but never advances the session.
      class DurableSessionEvidenceReader
        def initialize(env:, routing: :adaptive)
          @env = env
          @routing = routing
        end

        def call(runtime_dir:, thread:, provider:, model:)
          directory = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime_dir, env: @env)
          runtime = Tamoz::Agent::WorkerRuntime.open(
            directory,
            model_factory: ->(_profile:) { build_model(provider:, model:) },
            routing: @routing
          )
          view = runtime.session_for(thread).view(thread:)
          {
            'status' => view.status,
            'terminal' => view.terminal,
            'effect_receipts' => view.effect_receipts.map(&:to_h),
            'verification' => view.state.fetch(:verification, {})
          }
        ensure
          runtime&.close
        end

        private

        def build_model(provider:, model:)
          key = Tamoz::Agent::RubyLLMModel::ENV_KEYS.fetch(provider.downcase.to_sym)
          Tamoz::Agent::RubyLLMModel.new(
            provider:, model:, api_key: @env[key], api_base: @env["#{provider.upcase}_API_BASE"]
          )
        end
      end
    end
  end
end
