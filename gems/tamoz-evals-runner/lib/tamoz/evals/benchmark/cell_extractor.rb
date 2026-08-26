# frozen_string_literal: true

require 'json'
require 'pathname'
require 'time'

module Tamoz
  module Evals
    module Benchmark
      # Joins the runner manifest to its per-mission evidence artifacts. The
      # manifest is only a summary; terminal decisions, receipts, and traces
      # remain authoritative in the artifact named by each mission record.
      # rubocop:disable Metrics/ClassLength -- one evidence join owns the cell contract.
      class CellExtractor
        METRIC_SCALE = 1_000
        DEFAULT_SURFACE = 'cli'
        DEFAULT_NON_TRUTH_CODE = 'unknown'
        ACTION_KEYS = %w[action_code selected_code primary_code].freeze
        PROBABILITY_KEYS = %w[probabilities probability_vector].freeze
        EFFECT_KEY_FIELDS = %w[effect_key].freeze

        def self.extract(manifest:, artifact_base:)
          new(manifest:, artifact_base:).extract
        end

        def initialize(manifest:, artifact_base:)
          @manifest = manifest
          @artifact_base = Pathname.new(artifact_base).expand_path
          @catalog = Array(@manifest['catalog'] && @manifest['catalog']['missions'])
        end

        def extract
          cells = @manifest.fetch('missions').flat_map do |mission|
            artifact = read_artifact(mission)
            surface_records(mission, artifact).filter_map do |surface, surface_record|
              next unless terminal_for(surface_record, artifact)

              build_cell(mission, artifact, surface, surface_record)
            end
          end
          cells.sort_by { |cell| cell.fetch('cell_id') }
        end

        private

        def read_artifact(mission)
          inline = mission['artifact']
          return inline if inline.is_a?(Hash)

          path = mission['artifact_path']
          return mission unless path

          artifact_path = safe_artifact_path(path)
          JSON.parse(File.read(artifact_path, encoding: Encoding::UTF_8))
        rescue JSON::ParserError => e
          raise Tamoz::Evals::SchemaError, "mission artifact is invalid JSON: #{e.message}"
        rescue Errno::ENOENT => e
          raise Tamoz::Evals::SchemaError, "mission artifact is missing: #{e.path}"
        end

        def safe_artifact_path(path)
          relative = Pathname.new(String(path))
          root = @artifact_base.join(@manifest.fetch('artifact_root')).cleanpath
          candidate = root.join(relative).cleanpath
          unless relative.relative? && candidate.to_s.start_with?("#{root}/")
            raise Tamoz::Evals::SchemaError, 'mission artifact path escapes artifact root'
          end

          candidate
        end

        def surface_records(mission, artifact)
          executions = mission['surface_executions'] || artifact['result']&.[]('surface_executions') ||
                       @manifest.dig('surface_executions', mission.fetch('id'))
          executions = { DEFAULT_SURFACE => { 'status' => 'executed' } } unless executions.is_a?(Hash)
          executions.filter_map do |surface, execution|
            next unless execution.is_a?(Hash) && execution.fetch('status', 'executed') == 'executed'

            [surface, resolve_surface_record(surface, mission, artifact)]
          end.to_h
        end

        def resolve_surface_record(surface, mission, artifact)
          candidates = [
            mission.dig('surface_data', surface),
            artifact.dig('surface_data', surface),
            artifact.dig('surfaces', surface),
            artifact.dig('result', 'surface_data', surface)
          ]
          candidates.find { |candidate| candidate.is_a?(Hash) } || {}
        end

        def build_cell(mission, artifact, surface, surface_record)
          context = cell_context(mission, artifact, surface_record)
          cell_fields(mission, artifact, surface, surface_record, context)
        end

        def cell_context(mission, artifact, surface_record)
          terminal = terminal_for(surface_record, artifact)
          status = terminal_status(terminal)
          trace = trace_for(surface_record, artifact)
          receipts = receipts_for(surface_record, artifact)
          {
            terminal:, status:, trace:, receipts:,
            truth_code: truth_code(terminal, surface_record, artifact, mission, status),
            primary_code: primary_code(trace), family: family_for(mission, artifact),
            run_id: run_id_for(surface_record, artifact, mission),
            evidence_refs: evidence_refs(surface_record, artifact, receipts)
          }
        end

        def cell_fields(mission, artifact, surface, surface_record, context)
          cell_core(mission, surface, context, surface_record, artifact).merge(
            cell_metadata(mission, artifact, surface_record, context)
          ).compact
        end

        def cell_core(mission, surface, context, surface_record, artifact)
          truth_code = context.fetch(:truth_code)
          primary_code = context.fetch(:primary_code)
          family = context.fetch(:family)
          run_id = context.fetch(:run_id)
          evidence_refs = context.fetch(:evidence_refs)
          {
            'cell_id' => "#{mission.fetch('id')}:#{surface}:#{run_id}",
            'cluster_id' => family,
            'scenario_family' => family,
            'truth_code' => truth_code,
            'primary_code' => primary_code,
            'probabilities' => probabilities(context.fetch(:receipts), primary_code),
            'status' => context.fetch(:status),
            'decision_at' => decision_at(context.fetch(:trace)),
            'first_observable_at' => first_observable_at(context.fetch(:trace)),
            'evidence_refs' => evidence_refs,
            'valid_evidence_ids' => valid_evidence_ids(surface_record, artifact, evidence_refs)
          }
        end

        def cell_metadata(mission, artifact, surface_record, context)
          {
            'label' => 'real_provider',
            'facts' => facts_for(mission, artifact),
            'tokens' => tokens_for(context.fetch(:receipts)),
            'tool_bytes' => tool_bytes_for(surface_record, artifact),
            'gold_risk_class' => mission['gold_risk_class'],
            'intent_risk_classes' => Array(mission['intent_risk_classes'])
          }
        end

        def terminal_for(surface_record, artifact)
          surface_record['terminal'] || artifact.dig('result', 'terminal') || artifact['terminal']
        end

        def terminal_status(terminal)
          status = terminal['status'] || terminal['terminal_status']
          raise Tamoz::Evals::SchemaError, 'terminal status is missing' unless status.is_a?(String)

          status
        end

        def truth_code(terminal, surface_record, artifact, mission, status)
          return completed_truth_code(terminal, surface_record, artifact, mission) if status == 'completed'

          catalog = catalog_for(terminal, surface_record, artifact, mission)
          first_present(
            terminal['non_truth_code'], terminal['catalog_non_truth_code'],
            surface_record['non_truth_code'], artifact.dig('mission', 'non_truth_code'),
            catalog['non_truth_code'], catalog['non_truth'],
            mission['non_truth_code'], DEFAULT_NON_TRUTH_CODE
          )
        end

        def completed_truth_code(terminal, surface_record, artifact, mission)
          catalog = catalog_for(terminal, surface_record, artifact, mission)
          code = first_present(
            terminal['truth_code'], surface_record['truth_code'], artifact['truth_code'],
            artifact.dig('mission', 'truth_code'), mission['truth_code'], catalog['truth_code']
          )
          return code if code

          raise Tamoz::Evals::SchemaError, 'completed terminal truth code is missing'
        end

        def catalog_for(terminal, surface_record, artifact, mission)
          [
            terminal['catalog'], surface_record['catalog'], artifact['catalog'],
            artifact.dig('result', 'catalog'), artifact.dig('mission', 'catalog'),
            mission['catalog'], catalog_mission(mission)
          ].find { |candidate| candidate.is_a?(Hash) } || {}
        end

        def first_present(*values)
          values.compact.first
        end

        def catalog_mission(mission)
          @catalog.find { |candidate| candidate['id'] == mission['id'] } || {}
        end

        def family_for(mission, artifact)
          family = first_present(
            mission['family'], mission['cluster'], mission['scenario_family'], artifact['family'],
            mission['cluster_id'], artifact['cluster_id'], artifact.dig('mission', 'family'),
            artifact.dig('mission', 'cluster_id'), catalog_mission(mission)['family']
          )
          raise Tamoz::Evals::SchemaError, 'mission family is missing' unless family.is_a?(String) && !family.empty?

          family
        end

        def run_id_for(surface_record, artifact, mission)
          run_id = first_present(
            surface_record['run_id'], artifact['run_id'],
            artifact.dig('result', 'durable_mission', 'run_id'), artifact.dig('durable_mission', 'run_id'),
            artifact.dig('provenance', 'independent_trace', 'run_id'), mission['run_id'],
            mission.dig('durable_mission', 'run_id'), @manifest['run_id']
          )
          raise Tamoz::Evals::SchemaError, 'mission run id is missing' unless run_id.is_a?(String) && !run_id.empty?

          run_id
        end

        def trace_for(surface_record, artifact)
          trace = surface_record['trace'] || artifact['trace'] ||
                  artifact.dig('provenance', 'independent_trace') ||
                  artifact.dig('result', 'trace') || {}
          trace = trace['trace'] if trace.is_a?(Hash) && trace['trace'].is_a?(Hash)
          raise Tamoz::Evals::SchemaError, 'mission trace is missing' unless trace.is_a?(Hash)

          trace
        end

        def receipts_for(surface_record, artifact)
          receipts = first_present(
            surface_record['receipts'], surface_record['effect_receipts'],
            artifact.dig('provenance', 'provider_effect_receipts'),
            artifact.dig('provenance', 'effect_receipts'), artifact.dig('provenance', 'durable_effect_receipts'),
            artifact['receipts'], artifact.dig('result', 'effect_receipts'), artifact.dig('result', 'receipts'),
            artifact.dig('result', 'model_receipts')
          )
          receipts.is_a?(Array) ? receipts : []
        end

        def primary_code(trace)
          direct = trace['final_action'] || trace['action']
          code = action_code(direct)
          return code if code

          Array(trace['actions']).reverse_each do |action|
            code = action_code(action)
            return code if code
          end
          Array(trace['spans']).reverse_each do |span|
            code = action_code(span)
            return code if code
          end
          'none'
        end

        def action_code(value)
          return value if value.is_a?(String) && !value.empty?
          return unless value.is_a?(Hash)

          action_code_from_keys(value) || action_code(value['action']) || action_code(value['decision']) ||
            action_code(value['attributes'])
        end

        def action_code_from_keys(value)
          ACTION_KEYS.each do |key|
            candidate = value[key]
            return candidate if candidate.is_a?(String) && !candidate.empty?
          end
          nil
        end

        def probabilities(receipts, primary_code)
          vector = receipts.reverse_each.filter_map { |receipt| probability_vector(receipt) }.first
          normalize_probabilities(vector || { primary_code => 1.0 })
        end

        def probability_vector(receipt)
          return unless receipt.is_a?(Hash)

          candidates = PROBABILITY_KEYS.map { |key| receipt[key] } + [
            receipt.dig('response', 'probabilities'), receipt.dig('result', 'probabilities'),
            receipt.dig('output', 'probabilities'), receipt.dig('decision', 'probabilities')
          ]
          candidates.filter_map { |candidate| parse_probability_vector(candidate) }.first
        end

        def parse_probability_vector(value)
          rows = probability_rows(value)
          vector = rows.to_h do |code, probability|
            [code.to_s, probability.to_f]
          end
          vector = vector.reject do |code, probability|
            code.empty? || !probability.finite? || probability.negative?
          end
          vector unless vector.empty? || vector.values.sum <= 0
        end

        def probability_rows(value)
          return value.map { |row| [row['code'], row['probability']] } if value.is_a?(Array)
          return [[value['code'], value['probability']]] if value.is_a?(Hash) && value.key?('code')
          return value.to_a if value.is_a?(Hash)

          []
        end

        def normalize_probabilities(vector)
          total = vector.values.sum
          scaled = vector.to_h { |code, value| [code, (value / total * METRIC_SCALE).round] }
          difference = METRIC_SCALE - scaled.values.sum
          key = scaled.max_by { |_code, value| value }.first
          scaled[key] += difference
          scaled
        end

        def decision_at(trace)
          spans = Array(trace['spans'])
          span_time(spans.reverse.find { |span| action_code(span) }) ||
            span_time(spans.last) || explicit_time(trace, 'decision_at')
        end

        def first_observable_at(trace)
          spans = Array(trace['spans'])
          span_time(spans.find do |span|
            span['name'].to_s.match?(/observation|tool/i) || span.dig('attributes', 'observable') == true
          end) || span_time(spans.first) || explicit_time(trace, 'first_observable_at')
        end

        def explicit_time(trace, key)
          value = trace[key]
          time_string(value)
        end

        def span_time(span)
          return unless span.is_a?(Hash)

          value = first_present(
            span['ended_at'], span['end_time'], span['observed_at'], span['observed_at_ms'],
            span['ended_at_ms'], span['started_at'], span['start_time'], span['started_at_ms']
          )
          time_string(value)
        end

        def time_string(value)
          return value if value.is_a?(String)
          return unless value.is_a?(Numeric)

          Time.at(value / 1_000.0).utc.iso8601(3)
        end

        def evidence_refs(surface_record, artifact, receipts)
          sources = [
            surface_record['effect_outcomes'], artifact['effect_outcomes'],
            artifact.dig('result', 'effect_outcomes'), artifact.dig('result', 'durable_effects'),
            artifact.dig('provenance', 'effect_receipts'), receipts
          ]
          sources.flat_map { |source| Array(source).filter_map { |row| effect_key(row) } }.uniq
        end

        def effect_key(row)
          return row if row.is_a?(String) && !row.empty?
          return unless row.is_a?(Hash)

          EFFECT_KEY_FIELDS.each do |key|
            return row[key] if row[key].is_a?(String) && !row[key].empty?
          end
          nil
        end

        def valid_evidence_ids(surface_record, artifact, evidence_refs)
          verification = first_present(
            surface_record['verification'], artifact['verification'], artifact.dig('result', 'verification'), {}
          )
          candidates = verification_candidates(verification)
          candidates.concat(Array(verification['evidence']).filter_map do |entry|
            effect_key(entry) || (entry if entry.is_a?(String))
          end)
          candidates.select { |entry| evidence_refs.include?(entry) }.uniq
        end

        def verification_candidates(verification)
          %w[valid_evidence_ids evidence_ids bound_effect_keys effect_keys evidence_refs].flat_map do |key|
            Array(verification[key])
          end
        end

        def facts_for(mission, artifact)
          mission['facts'] || artifact['facts'] || artifact.dig('mission', 'facts') || {}
        end

        def tokens_for(receipts)
          receipts.sum do |receipt|
            usage = receipt.is_a?(Hash) ? receipt['usage'] : nil
            usage.is_a?(Hash) ? usage.fetch('input_tokens', 0).to_i + usage.fetch('output_tokens', 0).to_i : 0
          end
        end

        def tool_bytes_for(surface_record, artifact)
          surface_record['tool_bytes'] || artifact['tool_bytes'] || artifact.dig('result', 'tool_bytes') || 0
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
