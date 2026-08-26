# frozen_string_literal: true

require 'pathname'

module Tamoz
  module Evals
    module Benchmark
      # Commits the report and scoreboard entry for an accepted OpenClaw run.
      class OpenclawPublisher
        class Refusal < Tamoz::Evals::ExecutionError; end

        Result = Data.define(:report, :scoreboard)

        def self.publish(manifest:, protocol:, readiness:, artifact_base:, scoreboard_path:)
          new(
            manifest:, protocol:, readiness:, artifact_base:, scoreboard_path:
          ).publish
        end

        def initialize(manifest:, protocol:, readiness:, artifact_base:, scoreboard_path:)
          @manifest = manifest
          @protocol = protocol
          @readiness = readiness
          @artifact_base = Pathname.new(artifact_base).expand_path
          @scoreboard_path = scoreboard_path
        end

        def publish
          enforce_publishable!
          report = ComparisonExecutor.new(
            manifest: @manifest, protocol: @protocol, artifact_base: @artifact_base
          ).write(report_path)
          scoreboard = Scoreboard.append(
            manifest: @manifest, report:, scoreboard_path: @scoreboard_path,
            artifact_base: @artifact_base
          )
          Result.new(report:, scoreboard:)
        end

        private

        def enforce_publishable!
          return if @readiness.publishable?

          raise Refusal, 'benchmark is not publishable'
        end

        def report_path
          @artifact_base.join(@manifest.fetch('artifact_root'), 'report.json')
        end
      end
    end
  end
end
