# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'tempfile'

module Tamoz
  module Evals
    module Benchmark
      # Executes the canonical mission set through a caller-supplied session
      # adapter and writes provenance-bound evidence artifacts. The adapter is
      # deliberately injected: this runner owns mission identity and evidence
      # publication, not a second agent runtime or provider client.
      # rubocop:disable Metrics/ClassLength -- the runner keeps one bounded evidence contract together.
      class OpenclawMissionRunner
        SCHEMA_VERSION = 'openclaw.evidence.v1'
        METRICS_SCHEMA_VERSION = 'openclaw.metrics.v1'
        CATALOG_SCHEMA_VERSION = 'openclaw.missions.v1'
        RUN_KINDS = %w[fixture real_provider].freeze
        MISSION_STATUSES = %w[ready blocked failed unavailable unknown].freeze
        SURFACE_STATUSES = %w[executed blocked failed unavailable unknown].freeze
        HARD_ZERO_STATUSES = %w[passed failed unknown].freeze
        EFFECT_OUTCOME_STATUSES = %w[succeeded failed unknown].freeze
        SURFACE_FIELDS = %w[status provenance].freeze
        PROVIDER_RECEIPT_FIELDS = %w[effect_key operation status].freeze
        PROVIDER_RECEIPT_STATUSES = %w[succeeded].freeze
        MANIFEST_FILENAME = 'manifest.json'
        MISSION_ID_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,127}\z/
        MAX_ARTIFACT_BYTES = 131_072

        Result = Data.define(:manifest, :artifacts)

        def self.run(**arguments)
          new(**arguments).run
        end

        # rubocop:disable Metrics/AbcSize -- normalize one explicit runner binding.
        def initialize(**arguments)
          values = arguments.fetch_values(
            :protocol, :catalog, :run_kind, :provider, :model, :artifact_root, :artifact_base,
            :git_revision, :config_sha256, :graph, :surfaces, :capabilities, :controls_passed,
            :command, :executor
          )
          @protocol, @catalog, raw_run_kind, raw_provider, raw_model, raw_artifact_root,
            raw_artifact_base, raw_git_revision, raw_config_sha256, @graph, @surfaces,
            @capabilities, @controls_passed, raw_command, @executor = values
          @run_kind = String(raw_run_kind)
          @provider = String(raw_provider)
          @model = String(raw_model)
          @artifact_root = String(raw_artifact_root)
          @artifact_base = Pathname.new(raw_artifact_base)
          @git_revision = String(raw_git_revision)
          @config_sha256 = String(raw_config_sha256)
          @command = String(raw_command)
          validate_inputs!
        end
        # rubocop:enable Metrics/AbcSize

        # rubocop:disable Metrics/MethodLength -- assemble and persist one manifest atomically.
        def run
          artifact_directory = @artifact_base.join(@artifact_root)
          FileUtils.mkdir_p(artifact_directory)
          artifacts = @catalog.fetch('missions').map { |mission| run_mission(mission, artifact_directory) }
          manifest = {
            'runner_schema_version' => SCHEMA_VERSION,
            'protocol_sha256' => Readiness.protocol_digest(@protocol),
            'run_kind' => @run_kind,
            'provider' => @provider,
            'model' => @model,
            'artifact_root' => @artifact_root,
            'git_revision' => @git_revision,
            'config_sha256' => @config_sha256,
            'graph' => @graph,
            'surfaces' => @surfaces,
            'command' => @command,
            'capabilities' => @capabilities,
            'surface_executions' => artifacts.to_h do |artifact|
              [artifact.fetch('mission').fetch('id'), artifact.fetch('mission').fetch('surface_executions')]
            end,
            'missions' => artifacts.map { |artifact| artifact.fetch('mission') },
            'controls_passed' => @controls_passed
          }
          write_manifest(artifact_directory, manifest)
          Result.new(manifest:, artifacts: artifacts.freeze)
        end
        # rubocop:enable Metrics/MethodLength

        private

        def validate_inputs!
          validate_catalog!
          validate_run_kind!
          validate_identity!
          validate_artifact_root!
          validate_surfaces!
          validate_executor!
        end

        def validate_catalog!
          valid = valid_catalog_shape?
          raise SchemaError, 'OpenClaw mission catalog must contain missions' unless valid
          raise SchemaError, 'OpenClaw mission ids must be unique' unless mission_ids.uniq == mission_ids

          @catalog.fetch('missions').each { |mission| validate_catalog_mission!(mission) }
        end

        def valid_catalog_shape?
          @catalog.is_a?(Hash) && @catalog.keys.sort == %w[missions schema_version] &&
            @catalog['schema_version'] == CATALOG_SCHEMA_VERSION &&
            @catalog['missions'].is_a?(Array) && !@catalog['missions'].empty?
        end

        def validate_catalog_mission!(mission)
          validate_catalog_shape!(mission)
          validate_catalog_identity!(mission)
          validate_catalog_lists!(mission)
          return if mission.fetch('surfaces').sort == Readiness::MISSION_SURFACES.sort

          raise SchemaError, 'OpenClaw mission catalog surfaces are invalid'
        end

        def validate_catalog_shape!(mission)
          return if mission.is_a?(Hash) && mission.keys.sort == Readiness::MISSION_CATALOG_FIELDS.sort

          raise SchemaError, 'OpenClaw mission catalog mission fields are invalid'
        end

        def validate_catalog_identity!(mission)
          return if mission['id'].is_a?(String) && !mission['id'].empty? &&
                    MISSION_ID_PATTERN.match?(mission['id']) &&
                    mission['goal'].is_a?(String) && !mission['goal'].empty?

          raise SchemaError, 'OpenClaw mission catalog mission identity is invalid'
        end

        def validate_catalog_lists!(mission)
          %w[hard_zero metrics required_capabilities surfaces].each do |field|
            values = mission.fetch(field)
            next if values.is_a?(Array) && !values.empty? &&
                    values.all? { |value| value.is_a?(String) && !value.empty? }

            raise SchemaError, "OpenClaw mission catalog #{field} is invalid"
          end
        end

        def validate_run_kind!
          return if RUN_KINDS.include?(@run_kind)

          raise SchemaError, 'OpenClaw run_kind is invalid'
        end

        def validate_identity!
          return unless @provider.empty? || @model.empty?

          raise SchemaError, 'OpenClaw provider and model are required'
        end

        def validate_artifact_root!
          return if safe_path?(@artifact_root)

          raise SchemaError, 'OpenClaw artifact_root must be a safe relative path'
        end

        def validate_executor!
          return if @executor.respond_to?(:call)

          raise SchemaError, 'OpenClaw executor must respond to call'
        end

        def validate_surfaces!
          return if @surfaces.is_a?(Array) && @surfaces.uniq == @surfaces &&
                    @surfaces.all? { |surface| Readiness::MISSION_SURFACES.include?(surface) }

          raise SchemaError, 'OpenClaw surfaces are invalid'
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def run_mission(mission, artifact_directory)
          result = execute(mission)
          status = result.fetch('status')
          artifact = (write_artifact(mission, result, artifact_directory) if status == 'ready')
          mission_record = {
            'id' => mission.fetch('id'),
            'status' => status,
            'artifact_path' => artifact&.fetch('path'),
            'artifact_digest' => artifact&.fetch('digest'),
            'metrics' => result.fetch('metrics', {}),
            'metrics_schema_version' => result.fetch('metrics_schema_version'),
            'hard_zero' => result.fetch('hard_zero'),
            'effect_outcomes' => result.fetch('effect_outcomes'),
            'surface_executions' => result.fetch('surface_executions'),
            'durable_mission' => result['durable_mission']
          }.compact
          mission_record['reason'] = result.fetch('reason') if result['reason']
          {
            'mission' => mission_record,
            'artifact' => artifact,
            'reason' => result['reason']
          }.compact
        rescue StandardError => e
          failure = normalized_failure(mission, "artifact_error:#{e.class}")
          { 'mission' => mission_record(failure, mission), 'reason' => failure.fetch('reason') }
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def execute(mission)
          result = @executor.call(
            mission: mission,
            run_kind: @run_kind,
            provider: @provider,
            model: @model
          )
          validate_result(result, mission)
        rescue StandardError => e
          {
            'status' => 'blocked',
            'reason' => "executor_error:#{e.class}",
            'metrics' => unavailable_metrics(mission, 'executor_error'),
            'metrics_schema_version' => METRICS_SCHEMA_VERSION,
            'hard_zero' => unknown_hard_zeros(mission),
            'effect_outcomes' => [],
            'surface_executions' => unavailable_surfaces(mission, 'executor_error')
          }
        end

        def validate_result(result, mission)
          validate_result_shape!(result)
          normalized = normalize_result(result, mission)
          status = normalized.fetch('status')
          return normalized if status != 'ready'

          validate_ready_provenance!(normalized.fetch('provenance', nil), mission)
          normalized
        end

        def validate_result_shape!(result)
          raise SchemaError, 'mission executor must return an object' unless result.is_a?(Hash)
          return if MISSION_STATUSES.include?(result.fetch('status'))

          raise SchemaError, 'mission executor returned an invalid status'
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def normalize_result(result, mission)
          status = result.fetch('status')
          metrics = result.fetch('metrics', {})
          metrics = unavailable_metrics(mission, status).merge(metrics) unless status == 'ready'
          validate_metrics!(metrics, result.fetch('metrics_schema_version', METRICS_SCHEMA_VERSION), mission)
          hard_zero = result.fetch('hard_zero', nil)
          hard_zero = unknown_hard_zeros(mission).merge(hard_zero || {}) unless status == 'ready'
          hard_zero = normalize_hard_zeros(hard_zero, mission)
          effect_outcomes = normalize_effect_outcomes(result.fetch('effect_outcomes', []))
          surface_input = result.fetch('surface_executions', nil)
          surface_input = unavailable_surfaces(mission, status).merge(surface_input || {}) unless status == 'ready'
          surface_executions = normalize_surface_executions(
            surface_input, mission, status
          )
          status = outcome_status(status, hard_zero, effect_outcomes, surface_executions)
          provenance = result.fetch('provenance', {})
          raise SchemaError, 'OpenClaw mission provenance must be an object' unless provenance.is_a?(Hash)

          result.merge(
            'status' => status,
            'metrics' => metrics,
            'metrics_schema_version' => METRICS_SCHEMA_VERSION,
            'hard_zero' => hard_zero,
            'effect_outcomes' => effect_outcomes,
            'surface_executions' => surface_executions,
            'provenance' => provenance.merge('surface_executions' => surface_executions)
          )
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def validate_metrics!(metrics, schema_version, mission)
          unless schema_version == METRICS_SCHEMA_VERSION && metrics.is_a?(Hash) &&
                 metrics.keys.all?(String) && metrics.values.none?(&:nil?)
            raise SchemaError, 'OpenClaw mission metrics schema is invalid'
          end

          missing = mission.fetch('metrics') - metrics.keys
          return if missing.empty?

          raise SchemaError, "OpenClaw mission metrics are incomplete:#{missing.join(',')}"
        end

        def normalize_hard_zeros(hard_zero, mission)
          return unknown_hard_zeros(mission) if hard_zero.nil?
          raise SchemaError, 'OpenClaw hard-zero evidence must be an object' unless hard_zero.is_a?(Hash)

          expected = mission.fetch('hard_zero')
          missing = expected.reject { |name| HARD_ZERO_STATUSES.include?(hard_zero[name]) }
          raise SchemaError, "OpenClaw hard-zero evidence is incomplete:#{missing.join(',')}" unless missing.empty?

          hard_zero.slice(*expected)
        end

        def normalize_effect_outcomes(outcomes)
          valid = outcomes.is_a?(Array) && outcomes.all? do |outcome|
            outcome.is_a?(Hash) && outcome['effect_key'].is_a?(String) &&
              EFFECT_OUTCOME_STATUSES.include?(outcome['status'])
          end
          raise SchemaError, 'OpenClaw effect outcome evidence is invalid' unless valid

          keys = outcomes.map { |outcome| outcome.fetch('effect_key') }
          raise SchemaError, 'OpenClaw effect outcome identities are duplicated' unless keys.uniq == keys

          outcomes
        end

        def normalize_surface_executions(executions, mission, status)
          executions = unavailable_surfaces(mission, status) if executions.nil?
          raise SchemaError, 'OpenClaw surface execution evidence must be an object' unless executions.is_a?(Hash)

          expected = mission.fetch('surfaces')
          missing = expected.reject { |surface| executions.key?(surface) }
          raise SchemaError, "OpenClaw surface execution evidence is incomplete:#{missing.join(',')}" if missing.any?

          expected.to_h do |surface|
            record = executions.fetch(surface)
            validate_surface_execution!(surface, record)
            [surface, record]
          end
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def validate_surface_execution!(surface, record)
          unless record.is_a?(Hash) && record.keys.sort == SURFACE_FIELDS.sort &&
                 SURFACE_STATUSES.include?(record['status']) && record['provenance'].is_a?(Hash)
            raise SchemaError, "OpenClaw surface execution is invalid:#{surface}"
          end

          provenance = record.fetch('provenance')
          return if provenance['surface'] == surface && provenance['run_kind'] == @run_kind &&
                    provenance['provider'] == @provider && provenance['model'] == @model

          raise SchemaError, "OpenClaw surface provenance is invalid:#{surface}"
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def outcome_status(status, hard_zero, effect_outcomes, surface_executions)
          return 'blocked' if status == 'blocked'

          failed = hard_zero.value?('failed') || effect_outcomes.any? { |outcome| outcome['status'] == 'failed' }
          return 'failed' if failed

          unknown = hard_zero.value?('unknown') || effect_outcomes.any? { |outcome| outcome['status'] == 'unknown' }
          return 'unknown' if unknown

          return 'unavailable' if status == 'ready' && surface_executions.values.any? do |execution|
            execution['status'] != 'executed'
          end

          status
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def unavailable_metrics(mission, reason)
          mission.fetch('metrics').to_h do |metric|
            [metric, { 'status' => 'unavailable', 'reason' => reason }]
          end
        end

        def unknown_hard_zeros(mission)
          mission.fetch('hard_zero').to_h { |name| [name, 'unknown'] }
        end

        def unavailable_surfaces(mission, reason)
          mission.fetch('surfaces').to_h do |surface|
            [surface, {
              'status' => reason == 'executor_error' ? 'blocked' : reason,
              'provenance' => {
                'surface' => surface, 'run_kind' => @run_kind,
                'provider' => @provider, 'model' => @model, 'reason' => reason
              }
            }]
          end
        end

        def normalized_failure(mission, reason)
          {
            'status' => 'blocked', 'reason' => reason,
            'metrics' => unavailable_metrics(mission, reason),
            'metrics_schema_version' => METRICS_SCHEMA_VERSION,
            'hard_zero' => unknown_hard_zeros(mission),
            'effect_outcomes' => [],
            'surface_executions' => unavailable_surfaces(mission, reason),
            'provenance' => { 'run_kind' => @run_kind, 'provider' => @provider, 'model' => @model }
          }
        end

        def mission_record(result, mission)
          {
            'id' => mission.fetch('id'), 'status' => result.fetch('status'),
            'metrics' => result.fetch('metrics'),
            'metrics_schema_version' => result.fetch('metrics_schema_version'),
            'hard_zero' => result.fetch('hard_zero'),
            'effect_outcomes' => result.fetch('effect_outcomes'),
            'surface_executions' => result.fetch('surface_executions'),
            'reason' => result.fetch('reason')
          }
        end

        def validate_ready_provenance!(provenance, mission)
          unless provenance.is_a?(Hash) && provenance['run_kind'] == @run_kind &&
                 provenance['provider'] == @provider && provenance['model'] == @model
            raise SchemaError, 'ready mission is missing run-kind provenance'
          end
          return unless @run_kind == 'real_provider'

          receipts = provenance['provider_effect_receipts']
          validate_provider_receipts!(receipts)
          independent_trace = provenance.fetch('independent_trace')
          expected_digest = Readiness.provider_trace_digest(
            mission_digest: digest(mission), receipts:, independent_trace:
          )
          unless provenance['provider_trace_digest'] == expected_digest
            raise SchemaError, 'real-provider mission trace digest does not match its receipts'
          end

          validate_independent_trace!(independent_trace, receipts, mission)
        end

        def validate_provider_receipts!(receipts)
          unless valid_provider_receipts?(receipts)
            raise SchemaError, 'real-provider mission must include effect receipts'
          end

          nil
        end

        def valid_provider_receipts?(receipts)
          receipts.is_a?(Array) && !receipts.empty? &&
            receipts.map { |receipt| receipt['effect_key'] }.uniq == receipts.map { |receipt| receipt['effect_key'] } &&
            receipts.all? { |receipt| valid_provider_receipt?(receipt) }
        end

        def valid_provider_receipt?(receipt)
          return false unless receipt.is_a?(Hash)
          return false unless PROVIDER_RECEIPT_FIELDS.all? { |field| receipt[field].is_a?(String) }

          receipt.fetch('operation').start_with?('model.generate.') &&
            PROVIDER_RECEIPT_STATUSES.include?(receipt.fetch('status'))
        end

        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def validate_independent_trace!(evidence, receipts, mission)
          spans = evidence.is_a?(Hash) && evidence['trace'].is_a?(Hash) ? evidence['trace']['spans'] : nil
          model_spans = Array(spans).count { |span| span.is_a?(Hash) && span['name'] == 'tamoz.model.call' }
          valid = evidence.is_a?(Hash) && evidence['source'] == Readiness::INDEPENDENT_TRACE_SOURCE &&
                  evidence['trace_id'].is_a?(String) && !evidence['trace_id'].empty? &&
                  evidence['mission_id'] == mission.fetch('id') &&
                  evidence['run_id'].is_a?(String) && !evidence['run_id'].empty? &&
                  evidence['thread_id'].is_a?(String) && !evidence['thread_id'].empty? &&
                  Readiness::DIGEST_PATTERN.match?(evidence['trace_digest'].to_s) &&
                  evidence['trace'].is_a?(Hash) &&
                  evidence['trace_digest'] == digest(evidence['trace']) &&
                  model_spans >= receipts.length
          return if valid

          raise SchemaError, 'real-provider mission lacks independent trace evidence'
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def write_artifact(mission, result, artifact_directory)
          path = "#{mission.fetch('id')}.json"
          document = artifact_document(mission, result)
          bytes = "#{CanonicalJSON.dump(document)}\n"
          raise SchemaError, 'OpenClaw evidence artifact exceeds the size limit' if bytes.bytesize > MAX_ARTIFACT_BYTES

          atomic_write(artifact_directory.join(path), bytes, mission.fetch('id'))
          { 'path' => path, 'digest' => "sha256:#{Digest::SHA256.hexdigest(bytes)}" }
        end

        def write_manifest(artifact_directory, manifest)
          bytes = "#{CanonicalJSON.dump(manifest)}\n"
          raise SchemaError, 'OpenClaw evidence manifest exceeds the size limit' if
            bytes.bytesize > MAX_ARTIFACT_BYTES

          atomic_write(artifact_directory.join(MANIFEST_FILENAME), bytes, 'manifest')
          persisted = JSON.parse(File.read(artifact_directory.join(MANIFEST_FILENAME), encoding: Encoding::UTF_8))
          return if persisted == manifest

          raise SchemaError, 'OpenClaw generated manifest is inconsistent'
        end

        def artifact_document(mission, result)
          document = {
            'schema_version' => SCHEMA_VERSION,
            'protocol_sha256' => Readiness.protocol_digest(@protocol),
            'mission_id' => mission.fetch('id'),
            'mission_digest' => digest(mission),
            'run_kind' => @run_kind,
            'provider' => @provider,
            'model' => @model,
            'git_revision' => @git_revision,
            'config_sha256' => @config_sha256,
            'mission' => mission,
            'provenance' => result.fetch('provenance'),
            'result' => result.except('provenance')
          }
          raise Tamoz::SensitiveValueError, 'OpenClaw evidence contains a secret-shaped value' if
            Tamoz::Core.secret_shaped?(document)

          document
        end

        def atomic_write(path, bytes, mission_id)
          Tempfile.create([".#{mission_id}-", '.tmp'], path.dirname) do |temporary|
            temporary.write(bytes)
            temporary.flush
            temporary.fsync
            temporary.close
            File.rename(temporary.path, path)
          end
        end

        def mission_ids
          @catalog.fetch('missions').map { |mission| mission.fetch('id') }
        end

        def digest(value)
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(value))}"
        end

        def safe_path?(path)
          pathname = Pathname.new(path)
          !pathname.absolute? && pathname.each_filename.none?('..') && !path.empty?
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end

require_relative 'openclaw_durable_cli_adapter'
require_relative 'openclaw_comms_oracles'
require_relative 'openclaw_comms_fixture'
require_relative 'openclaw_comms_runner'
