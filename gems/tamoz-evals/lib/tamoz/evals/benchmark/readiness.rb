# frozen_string_literal: true

require 'digest'
require 'pathname'

module Tamoz
  module Evals
    module Benchmark
      # Validates the control-plane evidence needed before a benchmark report
      # may publish a final verdict. Scoring remains in Report; this boundary
      # only answers whether the run is sufficiently described and available.
      class Readiness
        DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
        RUN_KINDS = %w[fixture real_provider].freeze
        MISSION_STATUSES = %w[ready blocked unavailable].freeze
        CAPABILITY_FIELDS = %w[exists reachable authorized attempted effective completed verified].freeze
        BOOLEAN_VALUES = [true, false].freeze
        REQUIRED_FIELDS = %w[
          protocol_sha256 run_kind provider model artifact_root git_revision config_sha256
          graph surfaces command capabilities missions controls_passed
        ].freeze

        Result = Data.define(:status, :reasons, :manifest) do
          def ready? = status == 'ready'

          def publishable?
            ready? && manifest.fetch('run_kind') == 'real_provider' &&
              manifest.fetch('artifacts_verified', false) == true
          end

          def to_h
            {
              'status' => status,
              'reasons' => reasons,
              'publishable' => publishable?
            }
          end
        end

        class << self
          def evaluate(protocol:, manifest:, expected_mission_ids: nil, artifact_root_base: nil)
            validate_manifest!(manifest)
            reasons = evidence_reasons(protocol, manifest, expected_mission_ids, artifact_root_base)
            evaluated_manifest = manifest.merge(
              'artifacts_verified' => artifacts_verified?(manifest, artifact_root_base)
            )
            Result.new(
              status: reasons.empty? ? 'ready' : 'blocked',
              reasons: reasons.uniq.freeze,
              manifest: evaluated_manifest
            )
          end

          def assert_publishable!(protocol:, manifest:, expected_mission_ids: nil, artifact_root_base: nil)
            result = evaluate(protocol:, manifest:, expected_mission_ids:, artifact_root_base:)
            return result if result.publishable?

            raise Tamoz::Evals::ExecutionError,
                  "benchmark is not publishable: #{result.reasons.join(', ')}"
          end

          def protocol_digest(protocol)
            schema_error('benchmark protocol must be an object') unless protocol.is_a?(Hash)

            "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(protocol))}"
          end

          private

          def evidence_reasons(protocol, manifest, expected_mission_ids, artifact_root_base)
            structural_reasons(protocol, manifest, expected_mission_ids) +
              control_reasons(manifest, artifact_root_base)
          end

          def structural_reasons(protocol, manifest, expected_mission_ids)
            reasons = []
            reasons << 'protocol_digest_mismatch' unless protocol_digest(protocol) == manifest.fetch('protocol_sha256')
            reasons.concat(capability_reasons(manifest.fetch('capabilities')))
            reasons.concat(mission_reasons(manifest.fetch('missions')))
            reasons.concat(missing_mission_reasons(manifest.fetch('missions'), expected_mission_ids))
            reasons.concat(unexpected_mission_reasons(manifest.fetch('missions'), expected_mission_ids))
            reasons
          end

          def control_reasons(manifest, artifact_root_base)
            reasons = []
            reasons << 'fixture_or_fake_provider' if manifest.fetch('run_kind') == 'fixture'
            reasons.concat(artifact_reasons(manifest, artifact_root_base))
            reasons << 'controls_not_passed' unless manifest.fetch('controls_passed') == true
            reasons
          end

          def validate_manifest!(manifest)
            schema_error('benchmark evidence manifest must be an object') unless manifest.is_a?(Hash)

            validate_required_fields!(manifest)
            validate_protocol_and_run_kind!(manifest)
            validate_manifest_strings!(manifest)
            validate_binding_metadata!(manifest)
            validate_capabilities!(manifest.fetch('capabilities'))
            validate_missions!(manifest.fetch('missions'))
          end

          def validate_required_fields!(manifest)
            missing = REQUIRED_FIELDS.reject { |key| manifest.key?(key) }
            return if missing.empty?

            schema_error("benchmark evidence manifest missing #{missing.join(', ')}")
          end

          def validate_protocol_and_run_kind!(manifest)
            digest = manifest.fetch('protocol_sha256')
            raise Tamoz::Evals::DigestError, 'benchmark protocol digest is invalid' unless DIGEST_PATTERN.match?(digest)

            run_kind = manifest.fetch('run_kind')
            return if RUN_KINDS.include?(run_kind)

            schema_error('benchmark run_kind is invalid')
          end

          def validate_manifest_strings!(manifest)
            %w[provider model artifact_root git_revision command].each do |key|
              value = manifest.fetch(key)
              next if value.is_a?(String) && !value.empty?

              schema_error("benchmark #{key} must be a non-empty string")
            end

            expected_root = manifest.fetch('run_kind') == 'fixture' ? 'fixtures/' : 'real-provider/'
            artifact_root = manifest.fetch('artifact_root')
            return if artifact_root.start_with?(expected_root) && safe_artifact_path?(artifact_root)

            schema_error("benchmark artifact_root must start with #{expected_root.inspect}")
          end

          def validate_binding_metadata!(manifest)
            unless DIGEST_PATTERN.match?(manifest.fetch('config_sha256'))
              raise Tamoz::Evals::DigestError, 'benchmark configuration digest is invalid'
            end

            graph = manifest.fetch('graph')
            unless graph.is_a?(Hash) && graph['name'].is_a?(String) && graph['version'].is_a?(String)
              schema_error('benchmark graph binding is invalid')
            end

            surfaces = manifest.fetch('surfaces')
            return if surfaces.is_a?(Array) && %w[cli telegram].all? { |surface| surfaces.include?(surface) }

            schema_error('benchmark surfaces must include cli and telegram')
          end

          def validate_capabilities!(capabilities)
            unless capabilities.is_a?(Hash) && !capabilities.empty?
              schema_error('benchmark capabilities must be a non-empty object')
            end

            capabilities.each { |name, state| validate_capability!(name, state) }
          end

          def validate_capability!(name, state)
            unless name.is_a?(String) && state.is_a?(Hash) && state.keys.sort == CAPABILITY_FIELDS.sort
              schema_error("benchmark capability #{name.inspect} has an invalid state")
            end
            return if state.values.all? { |value| BOOLEAN_VALUES.include?(value) }

            schema_error("benchmark capability #{name.inspect} state must be boolean")
          end

          def validate_missions!(missions)
            unless missions.is_a?(Array) && !missions.empty?
              schema_error('benchmark missions must be a non-empty array')
            end

            missions.each { |mission| validate_mission!(mission) }
          end

          def validate_mission!(mission)
            unless mission.is_a?(Hash) && mission['id'].is_a?(String) &&
                   MISSION_STATUSES.include?(mission['status'])
              schema_error('benchmark mission has an invalid status')
            end
            return unless mission['status'] == 'ready'

            digest = mission['artifact_digest']
            path = mission['artifact_path']
            return if DIGEST_PATTERN.match?(digest.to_s) && safe_artifact_path?(path)

            raise Tamoz::Evals::DigestError, 'ready mission artifact binding is invalid'
          end

          def capability_reasons(capabilities)
            capabilities.filter_map do |name, state|
              missing = CAPABILITY_FIELDS.reject { |key| state.fetch(key) }
              "capability_unavailable:#{name}:#{missing.join('/')}" unless missing.empty?
            end
          end

          def mission_reasons(missions)
            missions.filter_map do |mission|
              status = mission.fetch('status')
              "mission_#{status}:#{mission.fetch('id')}" unless status == 'ready'
            end
          end

          def missing_mission_reasons(missions, expected_ids)
            return [] unless expected_ids

            actual = missions.map { |mission| mission.fetch('id') }
            Array(expected_ids).uniq.filter_map do |id|
              "mission_missing:#{id}" unless actual.include?(id)
            end
          end

          def unexpected_mission_reasons(missions, expected_ids)
            return [] unless expected_ids

            expected = Array(expected_ids).uniq
            missions.map { |mission| mission.fetch('id') }.uniq.filter_map do |id|
              "mission_unexpected:#{id}" unless expected.include?(id)
            end
          end

          def artifact_reasons(manifest, artifact_root_base)
            return ['artifacts_unverified'] unless artifact_root_base

            manifest.fetch('missions').filter_map do |mission|
              next unless mission.fetch('status') == 'ready'

              path = File.expand_path(
                File.join(manifest.fetch('artifact_root'), mission.fetch('artifact_path')),
                artifact_root_base
              )
              next "artifact_missing:#{mission.fetch('id')}" unless File.file?(path)

              actual = "sha256:#{Digest::SHA256.file(path).hexdigest}"
              next if actual == mission.fetch('artifact_digest')

              "artifact_digest_mismatch:#{mission.fetch('id')}"
            end
          end

          def artifacts_verified?(manifest, artifact_root_base)
            artifact_root_base && artifact_reasons(manifest, artifact_root_base).empty?
          end

          def safe_artifact_path?(path)
            path.is_a?(String) && !path.empty? && !Pathname.new(path).absolute? &&
              Pathname.new(path).each_filename.none?('..')
          end

          def schema_error(message)
            raise Tamoz::Evals::SchemaError, message
          end
        end
      end
    end
  end
end
