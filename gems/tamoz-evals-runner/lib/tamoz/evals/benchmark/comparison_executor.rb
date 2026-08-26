# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tempfile'

module Tamoz
  module Evals
    module Benchmark
      # Builds a report only from a real-provider run whose operator controls
      # passed. Refusal happens before artifact extraction or report writing.
      class ComparisonExecutor
        METRIC_SCALE = 1_000

        class Refusal < Tamoz::Evals::ExecutionError; end

        def self.build(manifest:, protocol:, artifact_base:)
          new(manifest:, protocol:, artifact_base:).build
        end

        def initialize(manifest:, protocol:, artifact_base:)
          @manifest = manifest
          @protocol = protocol
          @artifact_base = artifact_base
        end

        def build
          enforce_acceptance!
          cells = CellExtractor.extract(manifest: @manifest, artifact_base: @artifact_base)
          report = Report.build(
            protocol: @protocol,
            cells:,
            model_identity: model_identity,
            protocol_sha256: @manifest.fetch('protocol_sha256'),
            label: 'real_provider',
            controls_passed: true
          )
          canonicalize(report.merge('cells' => cells))
        end

        def write(report_out)
          report = build
          path = File.expand_path(report_out)
          FileUtils.mkdir_p(File.dirname(path))
          Tempfile.create(['.benchmark-openclaw-cells-', '.tmp'], File.dirname(path)) do |temporary|
            temporary.write("#{CanonicalJSON.dump(report)}\n")
            temporary.flush
            temporary.fsync
            temporary.close
            File.rename(temporary.path, path)
          end
          report
        end

        private

        def enforce_acceptance!
          raise Refusal, 'run_kind must be real_provider' unless @manifest['run_kind'] == 'real_provider'
          return if @manifest['controls_passed'] == true

          raise Refusal, 'controls_passed must be true'
        end

        def model_identity
          provider = @manifest.fetch('provider', '')
          model = @manifest.fetch('model')
          provider.empty? ? model : "#{provider}/#{model}"
        end

        def canonicalize(value)
          case value
          when Hash
            value.to_h { |key, entry| [key, canonicalize(entry)] }
          when Array
            value.map { |entry| canonicalize(entry) }
          when Float
            (value * METRIC_SCALE).round
          else
            value
          end
        end
      end
    end
  end
end
