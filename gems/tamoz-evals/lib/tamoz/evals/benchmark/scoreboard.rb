# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'pathname'
require 'tempfile'

module Tamoz
  module Evals
    module Benchmark
      # Owns the canonical, append-only longitudinal intelligence summary.
      # rubocop:disable Metrics/ClassLength
      class Scoreboard
        METRIC_SCALE = 1_000
        DEFAULT_COST_BUDGET = METRIC_SCALE
        ACKNOWLEDGED_NOTE_MARKER = 'reviewed regression:'

        AXES = %w[
          completion adaptive_continuation governance recovery external_tool_use self_knowledge memory cost
        ].freeze
        VERDICTS = %w[go negative inconclusive].freeze
        ENTRY_KEYS = %w[
          date git_revision sealed_build_digest protocol_sha256 provider model provider_model_version run_kind
          track artifact_root axes axis_verdicts hard_zero_fired notes
        ].freeze
        AXIS_MISSION_METRICS = {
          'completion' => { mission_ids: nil, metrics: %w[completion] },
          'adaptive_continuation' => {
            mission_ids: %w[adaptive-read-only], metrics: %w[adaptive_continuation completion]
          },
          'governance' => {
            mission_ids: %w[governed-mutation], metrics: %w[governance approval_correctness]
          },
          'recovery' => {
            mission_ids: %w[contradictory-observation compaction-restart scheduled-restart],
            metrics: %w[recovery]
          },
          'external_tool_use' => {
            mission_ids: %w[web-mcp], metrics: %w[external_tool_use tool_correctness]
          },
          'self_knowledge' => {
            mission_ids: %w[capability-availability self-inspection],
            metrics: %w[self_knowledge availability_accuracy inspection_correctness]
          },
          'memory' => {
            mission_ids: %w[memory-attribution], metrics: %w[memory retrieval_correctness]
          },
          'cost' => { mission_ids: nil, metrics: %w[cost] }
        }.freeze
        LOWER_IS_BETTER = %w[unnecessary_actions unknown_effect_rate duplicate_effect_rate latency].freeze
        REPORT_FILENAMES = %w[
          intervals.json axis_intervals.json report.json benchmark_report.json score_report.json
          scoreboard_report.json
        ].freeze

        class Error < Tamoz::Evals::ExecutionError; end
        class RegressionError < Error; end

        Result = Data.define(:entry, :document, :appended?)

        class << self
          def append(manifest:, report:, scoreboard_path:, artifact_base: nil, **)
            new(
              manifest:, report:, scoreboard_path:, artifact_base:, **
            ).append
          end

          def read(path)
            return { 'entries' => [] } unless File.file?(path)

            document = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
            normalize_document(document)
          rescue JSON::ParserError => e
            raise Error, "scoreboard JSON is invalid: #{e.message}"
          end

          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          def regression_check(scoreboard_path:, manifest:, artifact_base:)
            document = read(scoreboard_path)
            entries = document.fetch('entries')
            raise Error, 'scoreboard has no accepted entries' if entries.empty?

            current = entries.fetch(-1)
            validate_current_manifest!(current, manifest)
            return passed_regression(current) if entries.length == 1

            prior = entries.fetch(-2)
            intervals = intervals_for_entry(prior, artifact_base)
            missing = AXES.reject { |axis| intervals.key?(axis) }
            raise RegressionError, "prior artifact intervals are incomplete: #{missing.join(', ')}" unless
              missing.empty?

            drops = AXES.filter_map do |axis|
              current_value = current.fetch('axes').fetch(axis)
              prior_low = intervals.fetch(axis).fetch('low')
              next unless current_value < prior_low

              {
                'axis' => axis,
                'current' => current_value,
                'prior_interval_low' => prior_low,
                'prior_interval_high' => intervals.fetch(axis).fetch('high')
              }
            end
            acknowledged = acknowledged_note?(current.fetch('notes'))
            result = {
              'status' => drops.empty? || acknowledged ? 'passed' : 'failed',
              'artifact_root' => current.fetch('artifact_root'),
              'prior_artifact_root' => prior.fetch('artifact_root'),
              'acknowledged' => acknowledged,
              'regressions' => drops
            }
            return result if result.fetch('status') == 'passed'

            failed_axes = drops.map { |row| row.fetch('axis') }.join(', ')
            raise RegressionError, "unacknowledged scoreboard regression: #{failed_axes}"
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

          def intervals_for_entry(entry, artifact_base)
            root = artifact_directory(entry.fetch('artifact_root'), artifact_base)
            documents = interval_documents(root)
            AXES.filter_map do |axis|
              interval = documents.lazy.map { |document| find_interval(document, axis) }.find(&:itself)
              [axis, interval] if interval
            end.to_h
          end

          def acknowledged_note?(notes)
            notes.is_a?(String) && notes.start_with?(ACKNOWLEDGED_NOTE_MARKER)
          end

          private

          def normalize_document(document)
            entries = if document.is_a?(Array)
                        document
                      elsif document.is_a?(Hash) && document.keys == ['entries']
                        document.fetch('entries')
                      else
                        raise Error, 'scoreboard must be an object with an entries array'
                      end
            validate_entries!(entries)
            { 'entries' => entries }
          end

          def validate_entries!(entries)
            raise Error, 'scoreboard entries must be an array' unless entries.is_a?(Array)

            entries.each { |entry| validate_entry!(entry) }
            roots = entries.map { |entry| entry.fetch('artifact_root') }
            raise Error, 'scoreboard contains duplicate artifact_root entries' unless roots.uniq == roots
          end

          def validate_entry!(entry)
            raise Error, 'scoreboard entry must be an object' unless entry.is_a?(Hash)
            return if entry.keys.sort == ENTRY_KEYS.sort && valid_entry_values?(entry)

            raise Error, 'scoreboard entry shape is invalid'
          end

          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def valid_entry_values?(entry)
            entry.fetch('date').match?(/\A\d{4}-\d{2}-\d{2}\z/) &&
              string_or_nil?(entry.fetch('git_revision')) &&
              string_or_nil?(entry.fetch('sealed_build_digest')) &&
              string_or_nil?(entry.fetch('protocol_sha256')) &&
              string_value?(entry.fetch('provider')) && string_value?(entry.fetch('model')) &&
              string_or_nil?(entry.fetch('provider_model_version')) &&
              entry.fetch('run_kind') == 'real_provider' && string_value?(entry.fetch('track')) &&
              safe_artifact_root?(entry.fetch('artifact_root')) &&
              valid_axes?(entry.fetch('axes')) && valid_verdicts?(entry.fetch('axis_verdicts')) &&
              entry.fetch('hard_zero_fired').is_a?(Array) &&
              entry.fetch('hard_zero_fired').all?(String) &&
              entry.fetch('notes').is_a?(String) && !entry.fetch('notes').include?("\n")
          rescue KeyError, NoMethodError
            false
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def valid_axes?(axes)
            axes.is_a?(Hash) && axes.keys.sort == AXES.sort && axes.values.all? do |value|
              value.is_a?(Integer) && value.between?(0, METRIC_SCALE)
            end
          end

          def valid_verdicts?(verdicts)
            verdicts.is_a?(Hash) && verdicts.keys.sort == AXES.sort &&
              verdicts.values.all? { |value| VERDICTS.include?(value) }
          end

          def string_value?(value)
            value.is_a?(String) && !value.empty?
          end

          def string_or_nil?(value)
            value.nil? || string_value?(value)
          end

          def safe_artifact_root?(value)
            return false unless string_value?(value)

            pathname = Pathname.new(value)
            !pathname.absolute? && pathname.each_filename.none?('..')
          end

          def validate_current_manifest!(entry, manifest)
            unless manifest.is_a?(Hash) && manifest.fetch('run_kind') == 'real_provider' &&
                   manifest.fetch('controls_passed') == true
              raise Error, 'current manifest is not an accepted real_provider run'
            end
            return if entry.fetch('artifact_root') == manifest.fetch('artifact_root')

            raise Error, 'newest scoreboard entry does not match the manifest artifact_root'
          end

          def passed_regression(current)
            {
              'status' => 'passed', 'artifact_root' => current.fetch('artifact_root'),
              'prior_artifact_root' => nil, 'acknowledged' => false, 'regressions' => []
            }
          end

          def artifact_directory(artifact_root, artifact_base)
            raise Error, 'artifact_root is unsafe' unless safe_artifact_root?(artifact_root)

            Pathname.new(artifact_base).expand_path.join(artifact_root)
          end

          # rubocop:disable Metrics/AbcSize
          def interval_documents(root)
            paths = REPORT_FILENAMES.map { |name| root.join(name) }
            manifest_path = root.join('manifest.json')
            paths << manifest_path
            if File.file?(manifest_path)
              manifest = parse_json_file(manifest_path)
              %w[report_path report intervals_path axis_intervals_path].each do |key|
                reference = manifest[key]
                paths << root.join(reference) if reference.is_a?(String) && !Pathname.new(reference).absolute?
              end
            end
            paths.concat(root.glob('**/*report*.json')).concat(root.glob('**/*interval*.json'))
            paths.uniq.filter_map { |path| parse_json_file(path) if File.file?(path) }
          end
          # rubocop:enable Metrics/AbcSize

          def parse_json_file(path)
            JSON.parse(File.read(path, encoding: Encoding::UTF_8))
          rescue JSON::ParserError
            nil
          end

          def find_interval(document, axis)
            return nil unless document.is_a?(Hash)

            direct = interval_from(document[axis])
            return direct if direct

            %w[axis_intervals intervals axes report score].each do |key|
              nested = find_interval(document[key], axis)
              return nested if nested
            end
            nil
          end

          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def interval_from(value)
            return normalized_interval(value[0], value[1]) if value.is_a?(Array) && value.length == 2
            return nil unless value.is_a?(Hash)

            nested = value['interval'] || value['confidence_interval']
            return interval_from(nested) if nested

            low = value['low'] || value['ci_low'] || value['lower']
            high = value['high'] || value['ci_high'] || value['upper']
            normalized_interval(low, high) if !low.nil? && !high.nil?
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def normalized_interval(low, high)
            low = normalized_value(low)
            high = normalized_value(high)
            return nil unless low && high && low <= high

            { 'low' => low, 'high' => high }
          end

          def normalized_value(value)
            case value
            when Float
              return nil unless value.finite?

              value.between?(0.0, 1.0) ? (value * METRIC_SCALE).round : value.round
            when Integer
              value
            end.then { |number| number if number.is_a?(Integer) && number.between?(0, METRIC_SCALE) }
          end

          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def build_axis_verdicts(report)
            sources = [report['axis_verdicts'], report['verdicts']].grep(Hash)
            if report['axes'].is_a?(Hash)
              sources << report['axes'].to_h do |axis, value|
                [axis, value.is_a?(Hash) ? value['verdict'] : value]
              end
            end
            source = sources.find { |candidate| candidate.keys.any? { |key| AXES.include?(key) } } || {}
            scalar = report['verdict'] if VERDICTS.include?(report['verdict'])
            AXES.to_h do |axis|
              value = source[axis] || scalar || 'inconclusive'
              value = 'inconclusive' unless VERDICTS.include?(value)
              [axis, value]
            end
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def hard_zero_names(manifest, report)
            rows = Array(manifest['missions'])
            names = rows.flat_map do |mission|
              mission.fetch('hard_zero', {}).filter_map do |name, status|
                name if status != 'passed'
              end
            end
            names.concat(Array(report['hard_zero_fired']))
            names.grep(String).uniq.sort
          end
        end

        # rubocop:disable Metrics/ParameterLists
        def initialize(manifest:, report:, scoreboard_path:, artifact_base: nil, date: nil, notes: nil,
                       track: nil, provider_model_version: nil, sealed_build_digest: nil,
                       cost_budget: nil)
          @manifest = manifest
          @report = report
          @scoreboard_path = Pathname.new(scoreboard_path)
          @artifact_base = artifact_base
          @date = date
          @notes = notes
          @track = track
          @provider_model_version = provider_model_version
          @sealed_build_digest = sealed_build_digest
          @cost_budget = cost_budget
        end
        # rubocop:enable Metrics/ParameterLists

        def append
          validate_run!
          document = self.class.read(@scoreboard_path)
          existing = document.fetch('entries')
          duplicate = existing.find { |entry| entry.fetch('artifact_root') == @manifest.fetch('artifact_root') }
          return Result.new(entry: duplicate, document:, appended?: false) if duplicate

          entry = build_entry
          output = { 'entries' => existing + [entry] }
          self.class.send(:validate_entries!, output.fetch('entries'))
          write(output)
          Result.new(entry:, document: output, appended?: true)
        end

        private

        def validate_run!
          unless @manifest.is_a?(Hash) && @manifest.fetch('run_kind') == 'real_provider'
            raise Error, 'scoreboard accepts real_provider runs only'
          end
          raise Error, 'scoreboard accepts runs with controls_passed=true only' unless
            @manifest.fetch('controls_passed') == true
          unless self.class.send(:safe_artifact_root?, @manifest.fetch('artifact_root'))
            raise Error, 'manifest artifact_root is unsafe'
          end
          raise Error, 'scoreboard report must be an object' unless @report.is_a?(Hash)
        end

        # rubocop:disable Metrics/AbcSize
        def build_entry
          {
            'date' => entry_date,
            'git_revision' => @manifest.fetch('git_revision'),
            'sealed_build_digest' => @sealed_build_digest || @manifest['sealed_build_digest'] ||
              @report['sealed_build_digest'],
            'protocol_sha256' => @manifest.fetch('protocol_sha256'),
            'provider' => @manifest.fetch('provider'),
            'model' => @manifest.fetch('model'),
            'provider_model_version' => @provider_model_version || @manifest['provider_model_version'] ||
              @report['provider_model_version'],
            'run_kind' => @manifest.fetch('run_kind'),
            'track' => @track || @manifest['track'] || @report['track'] || 'common-subset',
            'artifact_root' => @manifest.fetch('artifact_root'),
            'axes' => build_axes,
            'axis_verdicts' => self.class.send(:build_axis_verdicts, @report),
            'hard_zero_fired' => self.class.send(:hard_zero_names, @manifest, @report),
            'notes' => entry_notes
          }
        end
        # rubocop:enable Metrics/AbcSize

        def build_axes
          missions = Array(@manifest['missions'])
          AXES.to_h do |axis|
            [axis, axis_score(axis, missions)]
          end
        end

        def axis_score(axis, missions)
          spec = self.class::AXIS_MISSION_METRICS.fetch(axis)
          selected = if spec[:mission_ids]
                       missions.select { |mission| spec[:mission_ids].include?(mission['id']) }
                     else
                       missions
                     end
          scores = selected.filter_map { |mission| metric_score(mission, spec[:metrics]) }
          return 0 if scores.empty?

          (scores.sum.to_f / scores.length).round
        end

        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def metric_score(mission, metric_names)
          metrics = mission.fetch('metrics', {})
          metric_name = metric_names.find { |name| metrics.key?(name) }
          return nil unless metric_name

          value = metrics.fetch(metric_name)
          return nil if value.is_a?(Hash) && value['status'] == 'unavailable'

          numeric = if value.is_a?(Hash)
                      value['normalized'] || value['score'] || value['value']
                    else
                      value
                    end
          return nil unless numeric.is_a?(Numeric)

          return cost_score(numeric) if metric_name == 'cost'
          return lower_score(numeric) if Scoreboard::LOWER_IS_BETTER.include?(metric_name)

          normalize_higher_score(numeric)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def normalize_higher_score(value)
          number = value.is_a?(Float) && value.between?(0.0, 1.0) ? value * METRIC_SCALE : value
          number.round.clamp(0, METRIC_SCALE)
        end

        def lower_score(value)
          normalized = value.is_a?(Float) && value.between?(0.0, 1.0) ? value : value.to_f / METRIC_SCALE
          (METRIC_SCALE * (1.0 - normalized)).round.clamp(0, METRIC_SCALE)
        end

        def cost_score(value)
          if value.is_a?(Float) && value.between?(0.0, 1.0)
            return (METRIC_SCALE * (1.0 - value)).round.clamp(0, METRIC_SCALE)
          end

          budget = (@cost_budget || @manifest['cost_budget'] || @report['cost_budget'] ||
            DEFAULT_COST_BUDGET).to_f
          raise Error, 'cost budget must be positive' unless budget.positive?

          (METRIC_SCALE * (1.0 - (value.to_f / budget))).round.clamp(0, METRIC_SCALE)
        end

        def entry_date
          candidate = @date || @manifest['date'] || @report['date'] || date_from_artifact_root
          return candidate if candidate.is_a?(String) && candidate.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          raise Error, 'scoreboard entry date is missing; pass --date or use a dated artifact_root'
        end

        def date_from_artifact_root
          value = @manifest.fetch('artifact_root')
          match = value.match(%r{(?:\A|/)(\d{4})-?(\d{2})-?(\d{2})(?:T|[-_])})
          match && [match[1], match[2], match[3]].join('-')
        end

        def entry_notes
          value = @notes || @manifest['notes'] || @report['notes'] || ''
          raise Error, 'scoreboard notes must be one bounded sentence' unless
            value.is_a?(String) && !value.include?("\n") && value.length <= 240

          value
        end

        def write(document)
          bytes = "#{CanonicalJSON.dump(document)}\n"
          FileUtils.mkdir_p(@scoreboard_path.dirname)
          Tempfile.create([".#{@scoreboard_path.basename}-", '.tmp'], @scoreboard_path.dirname) do |temporary|
            temporary.write(bytes)
            temporary.flush
            temporary.fsync
            temporary.close
            File.rename(temporary.path, @scoreboard_path)
          end
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
