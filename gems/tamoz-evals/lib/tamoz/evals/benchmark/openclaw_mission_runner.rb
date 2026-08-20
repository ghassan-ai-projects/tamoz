# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'

module Tamoz
  module Evals
    module Benchmark
      # Executes the canonical mission set through a caller-supplied session
      # adapter and writes provenance-bound evidence artifacts. The adapter is
      # deliberately injected: this runner owns mission identity and evidence
      # publication, not a second agent runtime or provider client.
      class OpenclawMissionRunner
        SCHEMA_VERSION = 'openclaw.evidence.v1'
        RUN_KINDS = %w[fixture real_provider].freeze
        MISSION_STATUSES = %w[ready blocked unavailable].freeze
        PROVIDER_CALLS = 'provider_calls'

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
            'missions' => artifacts.map { |artifact| artifact.fetch('mission') },
            'controls_passed' => @controls_passed
          }
          Result.new(manifest:, artifacts: artifacts.freeze)
        end

        private

        def validate_inputs!
          validate_catalog!
          validate_run_kind!
          validate_identity!
          validate_artifact_root!
          validate_executor!
        end

        def validate_catalog!
          valid = @catalog.is_a?(Hash) && @catalog['missions'].is_a?(Array) && !@catalog['missions'].empty?
          raise SchemaError, 'OpenClaw mission catalog must contain missions' unless valid
          raise SchemaError, 'OpenClaw mission ids must be unique' unless mission_ids.uniq == mission_ids

          @catalog.fetch('missions').each { |mission| validate_catalog_mission!(mission) }
        end

        def validate_catalog_mission!(mission)
          validate_catalog_shape!(mission)
          validate_catalog_identity!(mission)
          validate_catalog_lists!(mission)
          return if mission.fetch('surfaces').all? { |surface| Readiness::MISSION_SURFACES.include?(surface) }

          raise SchemaError, 'OpenClaw mission catalog surfaces are invalid'
        end

        def validate_catalog_shape!(mission)
          return if mission.is_a?(Hash) && mission.keys.sort == Readiness::MISSION_CATALOG_FIELDS.sort

          raise SchemaError, 'OpenClaw mission catalog mission fields are invalid'
        end

        def validate_catalog_identity!(mission)
          return if mission['id'].is_a?(String) && !mission['id'].empty? &&
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

        def run_mission(mission, artifact_directory)
          result = execute(mission)
          status = result.fetch('status')
          artifact = (write_artifact(mission, result, artifact_directory) if status == 'ready')
          mission_record = {
            'id' => mission.fetch('id'),
            'status' => status,
            'artifact_path' => artifact&.fetch('path'),
            'artifact_digest' => artifact&.fetch('digest')
          }.compact
          mission_record['reason'] = result.fetch('reason') if result['reason']
          {
            'mission' => mission_record,
            'artifact' => artifact,
            'reason' => result['reason']
          }.compact
        end

        def execute(mission)
          result = @executor.call(
            mission: mission,
            run_kind: @run_kind,
            provider: @provider,
            model: @model
          )
          validate_result(result)
        rescue StandardError => e
          {
            'status' => 'blocked',
            'reason' => "executor_error:#{e.class}:#{bounded(e.message)}"
          }
        end

        def validate_result(result)
          validate_result_shape!(result)
          status = result.fetch('status')
          return result if status != 'ready'

          validate_ready_provenance!(result.fetch('provenance', nil))
          result
        end

        def validate_result_shape!(result)
          raise SchemaError, 'mission executor must return an object' unless result.is_a?(Hash)
          return if MISSION_STATUSES.include?(result.fetch('status'))

          raise SchemaError, 'mission executor returned an invalid status'
        end

        def validate_ready_provenance!(provenance)
          unless provenance.is_a?(Hash) && provenance['run_kind'] == @run_kind &&
                 provenance['provider'] == @provider && provenance['model'] == @model
            raise SchemaError, 'ready mission is missing run-kind provenance'
          end
          return unless @run_kind == 'real_provider'
          return if provenance[PROVIDER_CALLS].is_a?(Integer) && provenance[PROVIDER_CALLS] >= 1

          raise SchemaError, 'real-provider mission must record a provider call'
        end

        def write_artifact(mission, result, artifact_directory)
          path = "#{mission.fetch('id')}.json"
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
          bytes = "#{CanonicalJSON.dump(document)}\n"
          artifact_path = artifact_directory.join(path)
          File.write(artifact_path, bytes, encoding: Encoding::UTF_8)
          { 'path' => path, 'digest' => "sha256:#{Digest::SHA256.hexdigest(bytes)}" }
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

        def bounded(value)
          String(value).byteslice(0, 256).to_s
        end
      end
    end
  end
end
