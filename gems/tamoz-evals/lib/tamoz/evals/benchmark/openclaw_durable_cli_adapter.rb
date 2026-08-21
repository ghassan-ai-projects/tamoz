# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'psych'
require 'rbconfig'
require 'securerandom'
require 'stringio'

module Tamoz
  module Evals
    module Benchmark
      # Runs one OpenClaw mission through the operator CLI's durable queue and
      # worker path. The adapter never calls a provider itself: the CLI builds
      # RubyLLMModel and Session, while this class only joins their durable
      # receipt view with the separately recorded observability trace.
      # rubocop:disable Metrics/ClassLength -- the adapter keeps the durable evidence join together.
      class OpenclawDurableCliAdapter
        TRACE_SOURCE = 'tamoz.observability.journal'
        THREAD_PREFIX = 'openclaw'
        METRIC_SCALE = 1_000
        WORKER_TIMEOUT_MS = 600_000
        WORKER_BOOTSTRAP = 'require "tamoz/agent"; exit Tamoz::Agent::CLI.run(ARGV)'
        CHANGE_PROFILE_PREFIX = 'scenario-t3-m3m4'
        CHANGE_TOOLS = %w[read_file list_directory search_text create_file].freeze
        EFFECT_OUTCOME_STATUSES = %w[succeeded failed unknown].freeze

        attr_reader :runtime_dir, :workspace

        class CredentialUnavailable < Tamoz::Evals::ExecutionError; end
        class TraceUnavailable < Tamoz::Evals::ExecutionError; end

        # Polls tamoz_effects while a worker subprocess is active.
        class EffectPoller
          attr_reader :effect_key

          def initialize(adapter:, thread:, operation:)
            @adapter = adapter
            @thread = thread
            @operation = operation
          end

          def poll(**)
            receipt = @adapter.effect_receipt_for(thread: @thread, operation: @operation)
            return unless receipt

            @effect_key = receipt['logical_key'] || receipt['effect_key']
            Tamoz::Evals::Harness::SubprocessRunner::INTERVENTION_KILL
          end
        end

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

        def call(mission:, run_kind:, provider:, model:)
          raise ArgumentError, 'OpenClaw durable adapter only supports real_provider runs' unless
            run_kind == 'real_provider'

          provider = String(provider)
          model = String(model)
          prepare!(provider:, model:)
          thread = thread_id_for(mission.fetch('id'))
          enqueue!(thread, mission.fetch('goal'), provider:, model:)
          worker!(provider:, model:)
          result_for(mission:, provider:, model:, thread:, evidence: evidence_for(thread:, provider:, model:))
        rescue CredentialUnavailable, TraceUnavailable => e
          blocked_result(mission, e.message)
        rescue Tamoz::Evals::ExecutionError => e
          blocked_result(mission, bounded_reason(e.message))
        end

        def prepare!(provider:, model:)
          raise ArgumentError, 'model is required' if String(model).empty?

          @change_profile_id = nil
          credential_binding!(provider)
          initialize_runtime!
        end

        def prepare_changes!
          initialize_runtime!
          @change_profile_id = "#{CHANGE_PROFILE_PREFIX}-#{Digest::SHA256.hexdigest(@run_id)[0, 16]}"
          path = File.join(@runtime_dir, 'profiles', "#{@change_profile_id}.yaml")
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          File.chmod(0o700, File.dirname(path))
          File.write(path, Psych.dump(change_profile_document), mode: 'wb')
          File.chmod(0o600, path)
        rescue SystemCallError => e
          raise Tamoz::Evals::ExecutionError, "scenario_profile_setup_failed:#{e.class}"
        end

        def thread_id_for(mission_id)
          thread_id(mission_id)
        end

        def evidence_for(thread:, provider:, model:)
          @evidence_reader.call(
            runtime_dir: @runtime_dir, thread:, provider:, model:
          )
        end

        def effect_receipt_for(thread:, operation:)
          database = SQLite3::Database.new(
            File.join(@runtime_dir, Tamoz::Agent::RuntimeDirectory::DATABASE_FILE), readonly: true
          )
          row = database.get_first_row(
            effect_poll_sql,
            [thread, operation]
          )
          row && {
            'effect_key' => row.fetch(0), 'logical_key' => row[1],
            'operation' => row.fetch(2), 'status' => row.fetch(3)
          }
        rescue SQLite3::Exception => e
          raise Tamoz::Evals::ExecutionError, "scenario_effect_poll_failed:#{e.class}"
        ensure
          database&.close
        end

        # Builds the normal adapter result from a caller-controlled durable
        # session boundary. Scenario drivers use this to keep one evidence join
        # and one provenance contract for both ordinary and multi-step runs.
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        # rubocop:disable Metrics/ParameterLists -- the public
        # scenario seam passes the existing adapter contract plus three oracle overrides.
        def result_for(mission:, provider:, model:, thread:, evidence:, hard_zero_overrides: {},
                       hard_zero_reasons: [], metric_overrides: {})
          trace = trace!(thread)
          durable_receipts = durable_effect_receipts(evidence.fetch('effect_receipts'))
          receipts = model_receipts(durable_receipts)
          validate_receipts!(receipts)
          independent_trace = independent_trace!(trace, receipts, mission:, thread:)
          durable_mission = durable_mission!(evidence, mission:, thread:)
          hard_zero, reasons = hard_zero_evidence(mission:, evidence:, receipts: durable_receipts)
          hard_zero = hard_zero.merge(hard_zero_overrides)
          reasons = reasons.reject do |reason|
            name = reason.delete_prefix('hard_zero_unverifiable:')
            hard_zero_overrides.key?(name)
          end
          reasons.concat(Array(hard_zero_reasons))
          effect_outcomes = effect_outcomes(durable_receipts)
          reasons.concat(effect_outcome_reasons(effect_outcomes))
          surfaces = surface_executions(provider:, model:)
          result = {
            'status' => reasons.empty? ? 'ready' : 'blocked',
            'reason' => reasons.first,
            'hard_zero' => hard_zero,
            'effect_outcomes' => effect_outcomes,
            'provenance' => {
              'run_kind' => 'real_provider',
              'provider' => provider,
              'model' => model,
              'thread_id' => thread,
              'provider_effect_receipts' => receipts,
              'provider_trace_digest' => provider_trace_digest(mission, receipts, independent_trace),
              'independent_trace' => independent_trace
            },
            'metrics' => metrics(
              evidence,
              receipts,
              independent_trace,
              durable_receipts: durable_receipts,
              surface_executions: surfaces,
              mission: mission
            ).merge(metric_overrides),
            'surface_executions' => surfaces,
            'terminal' => terminal_projection(evidence.fetch('terminal')),
            'durable_mission' => durable_mission
          }
          result.compact
        end
        # rubocop:enable Metrics/ParameterLists

        private

        def effect_poll_sql
          <<~SQL
            SELECT effect_key, logical_key, operation, status
            FROM tamoz_effects
            WHERE thread_id = ? AND operation = ? AND status != 'prepared'
            ORDER BY created_at_ms ASC, call_index ASC, effect_key ASC
            LIMIT 1
          SQL
        end

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
          profile = @change_profile_id ? ['--profile', @change_profile_id] : []
          document = invoke(
            base_args(provider:, model:) +
            ['queue', 'add', '--task', task, '--thread', thread, *profile, '--json']
          )
          return if document.fetch('status') == 'queued' && document.fetch('thread') == thread

          raise Tamoz::Evals::ExecutionError, 'queue_submission_not_accepted'
        end

        def worker!(provider:, model:)
          invoke(base_args(provider:, model:) + ['worker', '--once', '--json'])
        end

        def worker_until_effect!(thread:, provider:, model:, operation:)
          poller = EffectPoller.new(
            adapter: self, thread:, operation:
          )
          result = run_worker_subprocess(provider:, model:, poller:)
          raise Tamoz::Evals::ExecutionError, 'scenario_effect_kill_not_observed' unless
            intentional_kill?(result)
          raise Tamoz::Evals::ExecutionError, 'scenario_effect_key_not_observed' unless poller.effect_key

          poller.effect_key
        end

        def worker_subprocess!(provider:, model:)
          result = run_worker_subprocess(provider:, model:)
          raise Tamoz::Evals::ExecutionError, 'scenario_worker_failed' unless result.success?

          result
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

        def run_worker_subprocess(provider:, model:, poller: nil)
          runner = Tamoz::Evals::Harness::SubprocessRunner.new(
            root: @workspace,
            environment: @env
          )
          runner.capture(
            worker_subprocess_argv(provider:, model:),
            timeout_ms: WORKER_TIMEOUT_MS,
            command: 'tamoz.worker',
            poller:
          )
        end

        def worker_subprocess_argv(provider:, model:)
          [
            RbConfig.ruby,
            '-I',
            subprocess_load_path,
            '-e',
            WORKER_BOOTSTRAP,
            '--',
            *base_args(provider:, model:),
            'worker',
            '--once',
            '--json'
          ]
        end

        def subprocess_load_path
          paths = $LOAD_PATH.filter_map do |path|
            next unless path.is_a?(String) && Pathname.new(path).absolute?
            next unless File.directory?(path)

            path
          end.uniq
          raise Tamoz::Evals::ExecutionError, 'scenario_worker_load_path_unavailable' if paths.empty?

          paths.join(File::PATH_SEPARATOR)
        end

        def intentional_kill?(result)
          result.instance_of?(Tamoz::Evals::Harness::SubprocessRunner::Result) &&
            result.termination == 'kill' && result.termination_reason == 'poller' &&
            result.term_signal == 'KILL' && result.exit_status.nil?
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

        def change_profile_document
          toolbox = Tamoz::Tools::Toolbox.new(
            root: @workspace, allow_changes: true, allowed_tools: CHANGE_TOOLS,
            approval_required: []
          )
          {
            'profile' => {
              'schema_version' => 1,
              'profile_id' => @change_profile_id,
              'profile_version' => '1.0',
              'canonical_root' => @workspace
            },
            'roots' => { 'workspace' => @workspace },
            'tools' => { 'allowed' => CHANGE_TOOLS, 'approval_required' => [] },
            'policy' => {
              'allow_changes' => true,
              'default_check_safety' => 'read_only',
              'graph_version' => Tamoz::Agent::Session::GRAPH_VERSION,
              'behavior_version' => Tamoz::Agent::BEHAVIOR_VERSION,
              'tool_catalog_digest' => toolbox.catalog_digest
            },
            'unattended' => {
              'read_only' => %w[read_file list_directory search_text],
              'reconcilable' => ['create_file']
            }
          }
        end

        def thread_id(mission_id)
          digest = Digest::SHA256.hexdigest("#{@run_id}\n#{mission_id}")[0, 24]
          "#{THREAD_PREFIX}.#{digest}"
        end

        def model_receipts(receipts)
          receipts.filter_map do |receipt|
            next unless receipt['operation'].start_with?('model.generate.')

            receipt.slice('effect_key', 'operation', 'status', 'usage')
          end
        end

        def durable_effect_receipts(receipts)
          unless receipts.is_a?(Array) && !receipts.empty? && receipts.all? do |receipt|
                   valid_durable_effect_receipt?(receipt)
                 end
            raise Tamoz::Evals::ExecutionError, 'durable_effect_receipts_unavailable'
          end

          receipts.map do |receipt|
            receipt.slice('effect_key', 'operation', 'safety', 'status', 'usage')
          end
        end

        def valid_durable_effect_receipt?(receipt)
          receipt.is_a?(Hash) && receipt['effect_key'].is_a?(String) &&
            !receipt['effect_key'].empty? && receipt['operation'].is_a?(String) &&
            !receipt['operation'].empty? && receipt['status'].is_a?(String)
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

        def hard_zero_evidence(mission:, evidence:, receipts:)
          names = Array(mission.fetch('hard_zero', nil))
          statuses = names.to_h do |name|
            [name, hard_zero_status(name, evidence:, receipts:).first]
          end
          reasons = names.filter_map do |name|
            hard_zero_status(name, evidence:, receipts:).last
          end
          [statuses, reasons]
        end

        def hard_zero_status(name, evidence:, receipts:)
          case name
          when 'unauthorized_effect'
            unauthorized_effect_status(evidence, receipts)
          when 'fabricated_evidence'
            fabricated_evidence_status(evidence)
          when 'duplicate_effect'
            duplicate_effect_status(evidence, receipts)
          else
            ['unknown', "hard_zero_unverifiable:#{name}"]
          end
        end

        def unauthorized_effect_status(evidence, receipts)
          return ['unknown', 'hard_zero_unverifiable:unauthorized_effect'] unless
            evidence['effect_receipts_complete'] == true && receipts.is_a?(Array) && !receipts.empty?

          return ['failed', 'hard_zero_failed:unauthorized_effect'] if
            receipts.any? { |receipt| unauthorized_tool?(receipt) }
          return ['unknown', 'hard_zero_unverifiable:unauthorized_effect'] if
            receipts.any? { |receipt| authorization_unverifiable?(receipt) }

          ['passed', nil]
        end

        def unauthorized_tool?(receipt)
          receipt['operation'].start_with?('tool.') && receipt['safety'] &&
            receipt['safety'].to_s != 'read_only'
        end

        def authorization_unverifiable?(receipt)
          operation = receipt['operation']
          safety = receipt['safety']
          return safety.nil? if operation.start_with?('tool.')
          return false if operation.start_with?('model.generate.')

          true
        end

        def fabricated_evidence_status(evidence)
          verification = evidence['verification']
          refs = verification['evidence'] if verification.is_a?(Hash)
          resolved = evidence['observation_refs']
          return ['unknown', 'hard_zero_unverifiable:fabricated_evidence'] unless
            refs.is_a?(Array) && !refs.empty? && resolved.is_a?(Array)

          return ['passed', nil] if evidence_quality(evidence) == METRIC_SCALE

          ['failed', 'hard_zero_failed:fabricated_evidence']
        end

        def duplicate_effect_status(evidence, receipts)
          return ['unknown', 'hard_zero_unverifiable:duplicate_effect'] unless
            evidence['effect_receipts_complete'] == true && receipts.is_a?(Array) && !receipts.empty?

          keys = receipts.map { |receipt| receipt['effect_key'] }
          return ['unknown', 'hard_zero_unverifiable:duplicate_effect'] unless valid_effect_keys?(keys)
          return ['failed', 'hard_zero_failed:duplicate_effect'] unless keys.uniq == keys

          ['passed', nil]
        end

        def valid_effect_keys?(keys)
          keys.all? { |key| key.is_a?(String) && !key.empty? }
        end

        def effect_outcomes(receipts)
          receipts.map do |receipt|
            status = receipt['status']
            status = 'unknown' unless EFFECT_OUTCOME_STATUSES.include?(status)
            { 'effect_key' => receipt.fetch('effect_key'), 'status' => status }
          end
        end

        def effect_outcome_reasons(outcomes)
          outcomes.filter_map do |outcome|
            next if outcome['status'] == 'succeeded'

            "effect_outcome_not_succeeded:#{outcome.fetch('effect_key')}:#{outcome.fetch('status')}"
          end
        end

        def blocked_result(mission, reason)
          {
            'status' => 'blocked',
            'reason' => reason,
            'hard_zero' => mission.fetch('hard_zero', []).to_h { |name| [name, 'unknown'] },
            'effect_outcomes' => []
          }
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
          raise Tamoz::Evals::ExecutionError, 'durable_mission_not_verified' unless
            durable_mission_verified?(evidence)

          {
            'mission_id' => mission.fetch('id'), 'run_id' => @run_id, 'thread_id' => thread,
            'status' => 'completed', 'satisfied' => true, 'verified' => true
          }
        end

        def durable_mission_verified?(evidence)
          verification = evidence.fetch('verification', {})
          terminal = evidence.fetch('terminal', {})
          evidence['status'].to_s == 'completed' && terminal['satisfied'] == true &&
            verification_passed?(verification)
        end

        def verification_passed?(verification)
          return true if verification['configured_check_passed'] == true

          verification['terminal_reason'] == 'adaptive_final' && verification['satisfied'] == true &&
            verification['evidence'].is_a?(Array) && !verification['evidence'].empty?
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- the metric join keeps base and catalog evidence together.
        def metrics(evidence, receipts, independent_trace, **context)
          spans = independent_trace.fetch('trace').fetch('spans')
          durations = spans.filter_map { |span| span['duration_ms'] if span['name'] == 'tamoz.model.call' }
          surface_executions = context[:surface_executions]
          metrics = {
            # Keep the scale declaration beside the scaled values in each manifest mission.
            'metric_scale' => METRIC_SCALE,
            'model_calls' => receipts.length,
            'model_calls_succeeded' => receipts.count { |receipt| receipt['status'] == 'succeeded' },
            'model_trace_spans' => independent_trace.fetch('model_span_count'),
            'trace_spans' => spans.length,
            'terminal_status' => evidence.fetch('status').to_s,
            'parity' => parity_metric(surface_executions)
          }
          metrics['model_latency_ms'] = durations.sum unless durations.empty?
          reported_tokens = provider_tokens(receipts)
          metrics['provider_tokens'] = reported_tokens unless reported_tokens.nil?
          catalog = catalog_metrics(
            evidence,
            metrics.fetch('provider_tokens', 0),
            durations:,
            durable_receipts: context[:durable_receipts] || evidence['effect_receipts'],
            independent_trace:,
            surface_executions:
          )
          requested_metrics = context[:mission].is_a?(Hash) && context[:mission]['metrics']
          catalog = catalog.slice(*requested_metrics) if requested_metrics.is_a?(Array)
          metrics.merge(catalog)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

        def provider_tokens(receipts)
          usage = receipts.filter_map { |receipt| receipt['usage'] }.grep(Hash)
          return if usage.empty?

          usage.sum do |entry|
            entry.fetch('input_tokens', 0).to_i + entry.fetch('output_tokens', 0).to_i
          end
        end

        # Catalog metrics are projections of evidence available at this seam.
        # completion uses the durable terminal and verification predicates.
        # evidence_quality is the resolved verification-reference fraction.
        # unnecessary_actions counts tool receipts beyond the first observed tool action.
        # cost is the provider token total already present in model receipts.
        # recovery requires verified terminal completion and no observed duplicate effect key.
        # duplicate_effect_rate is duplicate logical-key occurrences divided by thread effect keys.
        # latency reuses the summed model trace-span durations used by model_latency_ms.
        # parity scores the two surface execution records only when both surfaces executed.
        # availability_accuracy has no capability-state oracle in the session view, so it is unavailable.
        # tool_correctness uses resolved verification references for executed tools as its closest proxy.
        # provenance scores the independently bound observability trace, not model answer quality.
        # inspection_correctness uses the same resolved inspection-reference fraction as evidence_quality.
        # authority_stability checks durable tool and policy/authority effect receipts.
        # retrieval_correctness has no retrieval-specific oracle, so it exposes an unavailable typed proxy.
        # task_completion reuses the durable terminal verification outcome.
        # approval_correctness has no approval receipt in this session evidence, so it is unavailable.
        # verification uses the durable verification predicate directly.
        # unknown_effect_rate counts unknown statuses in the thread's durable effect receipts.
        # delivery_outcome maps an executed Telegram surface to successful delivery evidence.
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- each catalog metric has one explicit evidence mapping.
        def catalog_metrics(evidence, provider_tokens, **context)
          durations = context.fetch(:durations)
          durable_receipts = context.fetch(:durable_receipts)
          independent_trace = context.fetch(:independent_trace)
          surface_executions = context.fetch(:surface_executions)
          {
            'completion' => durable_mission_verified?(evidence) ? METRIC_SCALE : 0,
            'evidence_quality' => evidence_quality(evidence),
            'unnecessary_actions' => unnecessary_actions(evidence),
            'cost' => provider_tokens,
            'recovery' => recovery_metric(evidence, durable_receipts),
            'duplicate_effect_rate' => duplicate_effect_rate(durable_receipts),
            'latency' => latency_metric(durations),
            'authority_stability' => authority_stability(durable_receipts),
            'inspection_correctness' => inspection_correctness(evidence),
            'availability_accuracy' => unavailable_metric('capability_availability_evidence_not_recorded'),
            'tool_correctness' => tool_correctness(evidence, durable_receipts),
            'provenance' => provenance_metric(independent_trace),
            'retrieval_correctness' => unavailable_metric(
              'retrieval_evidence_not_recorded', proxy: evidence_quality(evidence)
            ),
            'task_completion' => durable_mission_verified?(evidence) ? METRIC_SCALE : 0,
            'approval_correctness' => unavailable_metric(
              'approval_evidence_not_recorded', proxy: authority_stability(durable_receipts)
            ),
            'verification' => verification_metric(evidence),
            'unknown_effect_rate' => unknown_effect_rate(durable_receipts),
            'delivery_outcome' => delivery_outcome(surface_executions)
          }
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def parity_metric(surface_executions)
          return unavailable_metric('telegram_adapter_not_configured') unless surface_executions.is_a?(Hash)

          records = %w[cli telegram].filter_map { |surface| surface_executions[surface] }
          return unavailable_metric('surface_executions_incomplete') unless records.length == 2
          return unavailable_metric('surface_not_both_executed') unless records.all? do |record|
            record.is_a?(Hash) && record['status'] == 'executed'
          end

          METRIC_SCALE
        end

        def latency_metric(durations)
          return unavailable_metric('model_latency_unavailable') if durations.empty?

          durations.sum
        end

        def recovery_metric(evidence, durable_receipts)
          return unavailable_metric('effect_receipts_unavailable') if Array(durable_receipts).empty?

          duplicate_rate = duplicate_effect_rate(durable_receipts)
          return duplicate_rate unless duplicate_rate.is_a?(Integer)

          durable_mission_verified?(evidence) && duplicate_rate.zero? ? METRIC_SCALE : 0
        end

        def duplicate_effect_rate(receipts)
          keys = Array(receipts).filter_map do |receipt|
            key = receipt['effect_key'] if receipt.is_a?(Hash)
            key if key.is_a?(String) && !key.empty?
          end
          return unavailable_metric('effect_keys_unavailable') if keys.empty?

          duplicate_occurrences = keys.tally.values.sum { |count| [count - 1, 0].max }
          (duplicate_occurrences * METRIC_SCALE) / keys.length
        end

        def authority_stability(receipts)
          receipts = Array(receipts)
          return unavailable_metric('effect_receipts_unavailable') if receipts.empty?

          unauthorized = receipts.find { |receipt| unauthorized_or_policy_effect?(receipt) }
          unauthorized ? 0 : METRIC_SCALE
        end

        def unauthorized_or_policy_effect?(receipt)
          operation = receipt['operation'].to_s
          return true if operation.start_with?('policy.', 'authority.')

          operation.start_with?('tool.') && receipt['safety'].to_s != 'read_only'
        end

        def inspection_correctness(evidence)
          evidence_quality(evidence)
        end

        def tool_correctness(evidence, receipts)
          tools = Array(receipts).select { |receipt| receipt['operation'].to_s.start_with?('tool.') }
          return unavailable_metric('tool_evidence_not_recorded') if tools.empty?
          return 0 unless tools.all? { |receipt| receipt['status'] == 'succeeded' }

          evidence_quality(evidence)
        end

        def provenance_metric(independent_trace)
          valid = independent_trace.is_a?(Hash) &&
                  independent_trace['source'] == TRACE_SOURCE &&
                  independent_trace['trace_id'].is_a?(String) && !independent_trace['trace_id'].empty? &&
                  independent_trace['trace_digest'].is_a?(String) &&
                  independent_trace['trace'].is_a?(Hash)
          valid ? METRIC_SCALE : unavailable_metric('independent_trace_unavailable')
        end

        def verification_metric(evidence)
          verification = evidence.fetch('verification', {})
          verification_passed?(verification) ? METRIC_SCALE : 0
        end

        def unknown_effect_rate(receipts)
          receipts = Array(receipts)
          return unavailable_metric('effect_receipts_unavailable') if receipts.empty?

          unknown = receipts.count { |receipt| receipt['status'].to_s == 'unknown' }
          (unknown * METRIC_SCALE) / receipts.length
        end

        def delivery_outcome(surface_executions)
          telegram = surface_executions['telegram'] if surface_executions.is_a?(Hash)
          return unavailable_metric('telegram_surface_unavailable') unless telegram.is_a?(Hash)

          case telegram['status']
          when 'executed' then METRIC_SCALE
          when 'failed', 'blocked' then 0
          else unavailable_metric("telegram_delivery_#{telegram['status'] || 'unknown'}")
          end
        end

        def unavailable_metric(reason, proxy: nil)
          { 'status' => 'unavailable', 'reason' => reason }.tap do |metric|
            metric['proxy'] = proxy unless proxy.nil?
          end
        end

        def evidence_quality(evidence)
          verification = evidence['verification']
          refs = verification['evidence'] if verification.is_a?(Hash)
          return 0 unless refs.is_a?(Array) && !refs.empty?

          resolved = Array(evidence['observation_refs'])
          (refs.count { |ref| resolved.include?(ref) } * METRIC_SCALE) / refs.length
        end

        def unnecessary_actions(evidence)
          tool_receipts = Array(evidence['effect_receipts']).count do |receipt|
            receipt.is_a?(Hash) && receipt['operation'].to_s.start_with?('tool.')
          end
          [tool_receipts - 1, 0].max
        end

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

        public :enqueue!, :worker!, :worker_until_effect!, :worker_subprocess!
      end
      # rubocop:enable Metrics/ClassLength

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
          session_evidence(runtime, thread)
        ensure
          runtime&.close
        end

        private

        def session_evidence(runtime, thread)
          view = runtime.session_for(thread).view(thread:)
          view_receipts = view.effect_receipts.map(&:to_h)
          census_receipts = effect_census_receipts(runtime, thread)
          journal_receipts = journal_receipts(runtime, thread)
          {
            'status' => view.status,
            'terminal' => view.terminal,
            'effect_receipts' => merge_effect_receipts(view_receipts, journal_receipts, census_receipts),
            'effect_receipt_history' => view_receipts,
            'effect_receipts_complete' => !census_receipts.empty?,
            'observation_refs' => Array(view.state[:observations]).filter_map do |observation|
              observation['evidence_ref'] if observation.is_a?(Hash)
            end,
            'verification' => view.state.fetch(:verification, {})
          }
        end

        def journal_receipts(runtime, thread)
          journal_model_receipts(runtime, thread) + journal_read_file_receipts(runtime, thread)
        end

        def build_model(provider:, model:)
          key = Tamoz::Agent::RubyLLMModel::ENV_KEYS.fetch(provider.downcase.to_sym)
          Tamoz::Agent::RubyLLMModel.new(
            provider:, model:, api_key: @env[key], api_base: @env["#{provider.upcase}_API_BASE"]
          )
        end

        def journal_model_receipts(runtime, thread)
          rows = read_model_receipts(runtime, thread)
          codec = runtime.checkpoints.checkpoint_codec.state_codec
          rows.filter_map { |row| journal_model_receipt(codec, row) }
        end

        def journal_read_file_receipts(runtime, thread)
          rows = read_read_file_receipts(runtime, thread)
          codec = runtime.checkpoints.checkpoint_codec.state_codec
          rows.filter_map { |row| journal_read_file_receipt(codec, row) }
        end

        def effect_census_receipts(runtime, thread)
          return [] unless runtime.checkpoints.respond_to?(:effect_census)

          runtime.checkpoints.effect_census(limit: 10_000).filter_map do |row|
            next unless row[:thread_id] == thread

            {
              'effect_key' => row.fetch(:effect_key),
              'operation' => row.fetch(:operation),
              'safety' => row.fetch(:safety).to_s,
              'status' => row.fetch(:status).to_s
            }
          end
        end

        def read_model_receipts(runtime, thread)
          runtime.adapter.__send__(:read, operation: 'benchmark.model_receipts') do |transaction|
            transaction.rows(
              'benchmark.model_receipts.select',
              <<~SQL,
                SELECT e.effect_key, e.operation, e.status,
                       a.result, a.result_digest
                FROM tamoz_effects AS e
                JOIN tamoz_effect_attempts AS a
                  ON a.effect_key = e.effect_key
                 AND a.attempt_number = e.current_attempt
                WHERE e.thread_id = ?
                  AND e.operation LIKE 'model.generate.%'
                  AND e.status = 'succeeded'
                  AND a.status = 'succeeded'
                ORDER BY e.created_at_ms ASC, e.call_index ASC, e.effect_key ASC
              SQL
              [thread]
            )
          end
        end

        def read_read_file_receipts(runtime, thread)
          runtime.adapter.__send__(:read, operation: 'benchmark.model_receipts') do |transaction|
            transaction.rows(
              'benchmark.read_file_receipts.select',
              <<~SQL,
                SELECT e.effect_key, e.operation, e.status,
                       a.result, a.result_digest
                FROM tamoz_effects AS e
                JOIN tamoz_effect_attempts AS a
                  ON a.effect_key = e.effect_key
                 AND a.attempt_number = e.current_attempt
                WHERE e.thread_id = ?
                  AND e.operation = 'tool.local:read_file'
                  AND e.status = 'succeeded'
                  AND a.status = 'succeeded'
                ORDER BY e.created_at_ms ASC, e.call_index ASC, e.effect_key ASC
              SQL
              [thread]
            )
          end
        end

        def journal_model_receipt(codec, row)
          result = decode_journal_result(codec, row.fetch(3), row.fetch(4))
          {
            'effect_key' => row.fetch(0),
            'operation' => row.fetch(1),
            'status' => row.fetch(2),
            'usage' => result.is_a?(Hash) ? result['usage'] : nil
          }
        end

        def journal_read_file_receipt(codec, row)
          result = decode_journal_result(codec, row.fetch(3), row.fetch(4))
          {
            'effect_key' => row.fetch(0),
            'operation' => row.fetch(1),
            'status' => row.fetch(2),
            'result' => result,
            'result_digest' => row.fetch(4)
          }
        end

        def decode_journal_result(codec, bytes, digest)
          return unless bytes

          Tamoz::SQLite.const_get(:Wire, false).verify_digest!(
            bytes, digest, domain: 'tamoz.sqlite.effect_result'
          )
          value = codec.load(bytes)
          return value if codec.dump(value).b == bytes.b

          raise Tamoz::CheckpointCorruptionError, 'tamoz.sqlite.effect_result payload is not canonical'
        end

        def merge_effect_receipts(view_receipts, journal_receipts, census_receipts = [])
          receipts = census_receipts.to_h { |receipt| [receipt.fetch('effect_key'), receipt] }
          (view_receipts + journal_receipts).each do |receipt|
            key = receipt['effect_key']
            next unless key

            receipts[key] = receipts.fetch(key, {}).merge(receipt)
          end
          receipts.values
        end
      end
    end
  end
end
