# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

module Tamoz
  module Evals
    module Benchmark
      # Validates the control-plane evidence needed before a benchmark report
      # may publish a final verdict. Scoring remains in Report; this boundary
      # only answers whether the run is sufficiently described and available.
      # rubocop:disable Metrics/ClassLength -- schema and evidence gate live together.
      class Readiness
        DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
        RUN_KINDS = %w[fixture real_provider].freeze
        MISSION_STATUSES = %w[ready blocked unavailable].freeze
        CAPABILITY_FIELDS = %w[exists reachable authorized attempted effective completed verified].freeze
        MISSION_CATALOG_FIELDS = %w[goal hard_zero id metrics required_capabilities surfaces].freeze
        MISSION_SURFACES = %w[cli telegram].freeze
        MISSION_ID_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,127}\z/
        PROVIDER_RECEIPT_FIELDS = %w[effect_key operation status].freeze
        PROVIDER_RECEIPT_STATUSES = %w[succeeded failed unknown].freeze
        EVIDENCE_SCHEMA_VERSION = 'openclaw.evidence.v1'
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
          def evaluate(protocol:, manifest:, expected_mission_ids: nil, mission_catalog: nil, artifact_root_base: nil)
            validate_manifest!(manifest)
            validate_mission_catalog!(mission_catalog) if mission_catalog
            reasons = evidence_reasons(
              protocol, manifest, expected_mission_ids, mission_catalog, artifact_root_base
            )
            evaluated_manifest = manifest.merge(
              'artifacts_verified' => artifacts_verified?(manifest, artifact_root_base, mission_catalog)
            )
            Result.new(
              status: reasons.empty? ? 'ready' : 'blocked',
              reasons: reasons.uniq.freeze,
              manifest: evaluated_manifest
            )
          end

          def assert_publishable!(
            protocol:, manifest:, expected_mission_ids: nil, mission_catalog: nil, artifact_root_base: nil
          )
            result = evaluate(
              protocol:, manifest:, expected_mission_ids:, mission_catalog:, artifact_root_base:
            )
            return result if result.publishable?

            raise Tamoz::Evals::ExecutionError,
                  "benchmark is not publishable: #{result.reasons.join(', ')}"
          end

          def protocol_digest(protocol)
            schema_error('benchmark protocol must be an object') unless protocol.is_a?(Hash)

            "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(protocol))}"
          end

          private

          def evidence_reasons(protocol, manifest, expected_mission_ids, mission_catalog, artifact_root_base)
            structural_reasons(protocol, manifest, expected_mission_ids, mission_catalog) +
              control_reasons(manifest, artifact_root_base, mission_catalog)
          end

          def structural_reasons(protocol, manifest, expected_mission_ids, mission_catalog)
            reasons = []
            reasons << 'protocol_digest_mismatch' unless protocol_digest(protocol) == manifest.fetch('protocol_sha256')
            reasons.concat(capability_reasons(manifest.fetch('capabilities')))
            reasons.concat(mission_reasons(manifest.fetch('missions')))
            reasons.concat(required_capability_reasons(manifest, mission_catalog)) if mission_catalog
            reasons.concat(missing_mission_reasons(manifest.fetch('missions'), expected_mission_ids))
            reasons.concat(unexpected_mission_reasons(manifest.fetch('missions'), expected_mission_ids))
            reasons
          end

          def control_reasons(manifest, artifact_root_base, mission_catalog)
            reasons = []
            reasons << 'fixture_or_fake_provider' if manifest.fetch('run_kind') == 'fixture'
            reasons.concat(artifact_reasons(manifest, artifact_root_base, mission_catalog))
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

          def validate_mission_catalog!(catalog)
            schema_error('benchmark mission catalog must contain missions') unless valid_catalog_shape?(catalog)

            catalog.fetch('missions').each { |mission| validate_catalog_mission!(mission) }
            ids = catalog.fetch('missions').map { |mission| mission.fetch('id') }
            schema_error('benchmark mission catalog contains duplicate ids') unless ids.uniq == ids
          rescue KeyError, TypeError
            schema_error('benchmark mission catalog contains an invalid mission')
          end

          def valid_catalog_shape?(catalog)
            catalog.is_a?(Hash) && catalog.keys.sort == %w[missions schema_version] &&
              catalog['schema_version'] == 'openclaw.missions.v1' &&
              catalog['missions'].is_a?(Array) && !catalog['missions'].empty?
          end

          def validate_catalog_mission!(mission)
            validate_catalog_shape!(mission)
            validate_catalog_identity!(mission)
            validate_catalog_lists!(mission)
            return if mission.fetch('surfaces').sort == MISSION_SURFACES.sort

            schema_error('benchmark mission catalog surfaces are invalid')
          end

          def validate_catalog_shape!(mission)
            return if mission.is_a?(Hash) && mission.keys.sort == MISSION_CATALOG_FIELDS

            schema_error('benchmark mission catalog mission fields are invalid')
          end

          def validate_catalog_identity!(mission)
            valid = mission.fetch('id').is_a?(String) && MISSION_ID_PATTERN.match?(mission.fetch('id')) &&
                    mission.fetch('goal').is_a?(String) && !mission.fetch('goal').empty?
            return if valid

            schema_error('benchmark mission catalog mission identity is invalid')
          end

          def validate_catalog_lists!(mission)
            %w[hard_zero metrics required_capabilities surfaces].each do |field|
              next if valid_string_list?(mission.fetch(field))

              schema_error("benchmark mission catalog #{field} is invalid")
            end
          end

          def valid_string_list?(value)
            value.is_a?(Array) && !value.empty? && value.all? { |entry| entry.is_a?(String) && !entry.empty? }
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

          def required_capability_reasons(manifest, catalog)
            states = manifest.fetch('capabilities')
            catalog.fetch('missions').filter_map do |mission|
              next unless mission['required_capabilities'].is_a?(Array)

              missing = mission.fetch('required_capabilities').filter_map do |capability|
                state = states[capability]
                capability unless state&.values&.all?(true)
              end
              next if missing.empty?

              "mission_capability_unavailable:#{mission.fetch('id')}:#{missing.join('/')}"
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

          def artifact_reasons(manifest, artifact_root_base, mission_catalog = nil)
            return ['artifacts_unverified'] unless artifact_root_base

            manifest.fetch('missions').filter_map do |mission|
              artifact_reason_for(mission, manifest, artifact_root_base, mission_catalog)
            end
          end

          def artifact_reason_for(mission, manifest, artifact_root_base, mission_catalog)
            return unless mission.fetch('status') == 'ready'

            path = File.expand_path(
              File.join(manifest.fetch('artifact_root'), mission.fetch('artifact_path')),
              artifact_root_base
            )
            return "artifact_missing:#{mission.fetch('id')}" unless File.file?(path)

            actual = "sha256:#{Digest::SHA256.file(path).hexdigest}"
            return "artifact_digest_mismatch:#{mission.fetch('id')}" unless actual == mission.fetch('artifact_digest')

            document_reasons = artifact_document_reasons(path, mission, manifest, mission_catalog)
            document_reasons.empty? ? nil : document_reasons.first
          rescue SystemCallError, EncodingError => e
            "artifact_unavailable:#{mission.fetch('id')}:#{e.class}"
          end

          def artifacts_verified?(manifest, artifact_root_base, mission_catalog = nil)
            artifact_root_base && artifact_reasons(manifest, artifact_root_base, mission_catalog).empty?
          end

          def artifact_document_reasons(path, mission, manifest, mission_catalog)
            document = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
            return ["artifact_secret_value:#{mission.fetch('id')}"] if Tamoz::Core.secret_shaped?(document)

            reason = artifact_binding_reason(document, mission, manifest)
            return [reason] if reason

            reason = artifact_shape_reason(document, mission)
            return [reason] if reason

            reason = artifact_mission_reason(document, mission, mission_catalog)
            return [reason] if reason

            reason = artifact_provenance_reason(document, mission, manifest)
            reason ? [reason] : []
          rescue JSON::ParserError, TypeError
            ["artifact_schema_invalid:#{mission.fetch('id')}"]
          rescue SystemCallError, EncodingError => e
            ["artifact_unavailable:#{mission.fetch('id')}:#{e.class}"]
          end

          def artifact_binding_reason(document, mission, manifest)
            expected = {
              'schema_version' => EVIDENCE_SCHEMA_VERSION,
              'protocol_sha256' => manifest.fetch('protocol_sha256'),
              'mission_id' => mission.fetch('id'),
              'run_kind' => manifest.fetch('run_kind'),
              'provider' => manifest.fetch('provider'),
              'model' => manifest.fetch('model'),
              'git_revision' => manifest.fetch('git_revision'),
              'config_sha256' => manifest.fetch('config_sha256')
            }
            return if expected.all? { |key, value| document[key] == value }

            "artifact_binding_mismatch:#{mission.fetch('id')}"
          end

          def artifact_shape_reason(document, mission)
            return if document['mission'].is_a?(Hash) && document['result'].is_a?(Hash) &&
                      document['provenance'].is_a?(Hash)

            "artifact_shape_invalid:#{mission.fetch('id')}"
          end

          def artifact_mission_reason(document, mission, mission_catalog)
            return "artifact_mission_digest_mismatch:#{mission.fetch('id')}" unless
              document['mission_digest'] == canonical_digest(document['mission'])
            return unless mission_catalog

            catalog_mission = mission_catalog.fetch('missions').find { |entry| entry['id'] == mission.fetch('id') }
            return if catalog_mission && document['mission_digest'] == canonical_digest(catalog_mission)

            "artifact_mission_mismatch:#{mission.fetch('id')}"
          end

          def artifact_provenance_reason(document, mission, manifest)
            provenance = document['provenance']
            return "artifact_provenance_mismatch:#{mission.fetch('id')}" unless
              provenance['run_kind'] == manifest.fetch('run_kind') &&
              provenance['provider'] == manifest.fetch('provider') &&
              provenance['model'] == manifest.fetch('model')
            return unless manifest.fetch('run_kind') == 'real_provider'

            receipts = provenance['provider_effect_receipts']
            return "artifact_provider_receipts_invalid:#{mission.fetch('id')}" unless valid_provider_receipts?(receipts)

            expected_digest = canonical_digest(
              'mission_digest' => document.fetch('mission_digest'), 'receipts' => receipts
            )
            return if provenance['provider_trace_digest'] == expected_digest

            "artifact_provider_trace_mismatch:#{mission.fetch('id')}"
          end

          def valid_provider_receipts?(receipts)
            receipts.is_a?(Array) && !receipts.empty? &&
              receipts.all? { |receipt| valid_provider_receipt?(receipt) } &&
              receipts.any? { |receipt| receipt.fetch('status') == 'succeeded' }
          end

          def valid_provider_receipt?(receipt)
            receipt.is_a?(Hash) && PROVIDER_RECEIPT_FIELDS.all? { |field| receipt[field].is_a?(String) } &&
              receipt.fetch('operation').start_with?('model.generate.') &&
              PROVIDER_RECEIPT_STATUSES.include?(receipt.fetch('status'))
          end

          def canonical_digest(value)
            "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(value))}"
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
      # rubocop:enable Metrics/ClassLength
    end
  end
end
