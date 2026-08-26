# frozen_string_literal: true

require 'json'

module Tamoz
  module Evals
    module Runner
      # CLI for runner-owned scorecard and treatment operations.
      class CLI
        SUCCESS = Tamoz::Evals::CLI::SUCCESS
        GATE_FAILURE = Tamoz::Evals::CLI::GATE_FAILURE
        INVALID_EVIDENCE = Tamoz::Evals::CLI::INVALID_EVIDENCE
        INFRASTRUCTURE_FAILURE = Tamoz::Evals::CLI::INFRASTRUCTURE_FAILURE
        USAGE_ERROR = Tamoz::Evals::CLI::USAGE_ERROR

        def self.run(argv, out: $stdout, err: $stderr, scorecard_factory: nil, treatment_factory: nil)
          new(out:, err:, scorecard_factory:, treatment_factory:).run(argv)
        end

        def initialize(out:, err:, scorecard_factory:, treatment_factory:)
          @out = out
          @err = err
          @scorecard_factory = scorecard_factory
          @treatment_factory = treatment_factory
        end

        def run(argv)
          command, name, *options = argv
          return usage_message(command) unless valid_arguments?(command, name, options)

          dispatch(command, options.last)
        rescue InputManifest::Invalid => e
          @err.puts(e.message)
          USAGE_ERROR
        rescue Tamoz::Evals::InvalidArtifactError => e
          @err.puts("runner: invalid evidence: #{e.message}")
          INVALID_EVIDENCE
        rescue Tamoz::Evals::ExecutionError => e
          @err.puts(e.message)
          INFRASTRUCTURE_FAILURE
        end

        private

        def usage_message(command)
          expected_command = %w[scorecard treatment].include?(command) ? command : 'scorecard'
          expected_name = expected_command == 'treatment' ? 'memory' : 'agent-smoke'
          usage("expected: tamoz-eval-runner #{expected_command} #{expected_name} --input-manifest PATH")
        end

        def valid_arguments?(command, name, options)
          expected_name = command == 'scorecard' ? 'agent-smoke' : 'memory'
          %w[scorecard treatment].include?(command) && name == expected_name &&
            options.length == 2 && options.first == '--input-manifest' && options.last
        end

        def dispatch(command, manifest_path)
          manifest = InputManifest.from_path(
            manifest_path, package_roots: [PACKAGE_ROOT, Tamoz::Evals::DATA_ROOT.to_s]
          )
          load_scripted_model_responses!(manifest)
          load_scripted_model_adapter!(manifest) if selected_factory(command).nil?
          command == 'scorecard' ? run_scorecard(manifest) : run_treatment(manifest)
        end

        def selected_factory(command)
          command == 'scorecard' ? @scorecard_factory : @treatment_factory
        end

        def load_scripted_model_adapter!(manifest)
          InputAdapters.load_scripted_model_adapter!(
            path: manifest.scripted_model.fetch('adapter').fetch('path'),
            sha256: manifest.scripted_model.fetch('adapter').fetch('sha256'),
            package_roots: [PACKAGE_ROOT, Tamoz::Evals::DATA_ROOT.to_s]
          )
        end

        def load_scripted_model_responses!(manifest)
          InputAdapters.load_scripted_model_responses!(
            path: manifest.scripted_model.fetch('responses').fetch('path'),
            sha256: manifest.scripted_model.fetch('responses').fetch('sha256'),
            package_roots: [PACKAGE_ROOT, Tamoz::Evals::DATA_ROOT.to_s]
          )
        end

        def run_scorecard(manifest)
          factory = @scorecard_factory || InputAdapters.scorecard_factory
          return run_gate('agent-smoke') { invoke_factory(factory, manifest).run } if factory

          run_gate('agent-smoke') do
            raise Tamoz::Evals::ExecutionError,
                  'agent smoke scorecard factory is missing from the external adapter'
          end
        end

        def run_treatment(manifest)
          factory = @treatment_factory || InputAdapters.treatment_factory
          return run_gate('treatment memory') { invoke_factory(factory, manifest).run } if factory

          run_gate('treatment memory') do
            raise Tamoz::Evals::ExecutionError,
                  'memory treatment factory is missing from the external adapter'
          end
        end

        def run_gate(label)
          report = yield
          @out.puts(report.to_json)
          report.passed? ? SUCCESS : GATE_FAILURE
        rescue Tamoz::Evals::InvalidArtifactError => e
          @err.puts("#{label}: invalid evidence: #{e.message}")
          INVALID_EVIDENCE
        rescue Tamoz::Evals::ExecutionError => e
          @err.puts("#{label}: infrastructure failure: #{e.message}")
          INFRASTRUCTURE_FAILURE
        end

        def invoke_factory(factory, manifest)
          accepts_manifest = factory.respond_to?(:parameters) &&
                             factory.parameters.any? do |kind, name|
                               kind == :keyrest || (kind == :keyreq && name == :input_manifest)
                             end
          accepts_manifest ? factory.call(input_manifest: manifest) : factory.call
        rescue ArgumentError => e
          raise Tamoz::Evals::ExecutionError,
                "runner external factory invocation failed: #{e.message}"
        end

        def usage(message)
          @err.puts(message)
          USAGE_ERROR
        end
      end
    end
  end
end
