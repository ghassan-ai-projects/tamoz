# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz improve promote --bundle FILE --approval human:<actor> [--actor ID]`.
    module CLIImprovePromoteCommands
      # Records a promotion through the gem's own gates (report verifies/resolves,
      # no self-promotion, human gate, holdout passed, provenance complete). ADR-023:
      # it activates at the next thread's first intake, never an in-flight thread.
      def cmd_improve_promote(options, argv)
        bundle_path, approval, actor = parse_promote_options(argv)
        usage_error = promote_usage_error(bundle_path, approval)
        if usage_error
          @err.puts usage_error
          return 2
        end

        promotion = load_promotion(bundle_path)
        with_worker_runtime(options) { |runtime| promote_with(runtime, promotion, approval, actor) }
      rescue KeyError => e
        @err.puts "improve promote: malformed bundle (missing #{e.message})"
        2
      rescue Improvement::ImprovementError => e
        @err.puts "improve promote: refused — #{e.class.name.split('::').last}: #{e.message}"
        1
      end

      private

      def promote_usage_error(bundle_path, approval)
        unless bundle_path && File.exist?(bundle_path)
          return 'improve promote: --bundle FILE is required and must exist'
        end

        'improve promote: --approval "human:<actor>" is required' unless approval.to_s.start_with?('human:')
      end

      def load_promotion(bundle_path)
        bundle = JSON.parse(File.read(bundle_path))
        candidate = load_candidate(bundle.fetch('candidate'))
        provenance = load_provenance(bundle.fetch('provenance'))
        report = bundle.fetch('report')
        body = Improvement::EvaluationReport.verify!(report)
        resolver = ->(seal) { seal == Improvement::EvaluationReport.seal(body) ? report : nil }
        { candidate:, provenance:, report:, evidence_resolver: resolver }
      end

      def promote_with(runtime, promotion, approval, actor)
        engine = runtime.memory_engine
        unless engine
          @err.puts 'improve promote: memory is not enabled for this runtime'
          return 1
        end
        result = Improvement::Promotion.new(engine).promote(
          **promotion, human_gate_evidence: approval, actor: actor || 'operator'
        )
        transition = result.fetch('transition')
        state = result.fetch('activated') ? 'activated' : "pending activation at the next thread's first intake"
        @out.puts "improve promote: recorded #{transition.transition_id} (#{state})."
        0
      end

      def parse_promote_options(argv)
        bundle = nil
        approval = nil
        actor = nil
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz improve promote --bundle FILE --approval human:<actor> [--actor ID]'
          value.on('--bundle FILE', 'The vetted candidate bundle from the improvement pipeline') do |path|
            bundle = path
          end
          value.on('--approval EVIDENCE', 'Human approval, e.g. human:operator-1') { |evidence| approval = evidence }
          value.on('--actor ID', 'The promoting principal (default: operator)') { |id| actor = id }
        end.parse!(Array(argv).dup)
        [bundle, approval, actor]
      end

      def load_candidate(hash)
        Improvement::Heuristic.new(
          heuristic_id: hash.fetch('heuristic_id'), surface: hash.fetch('surface').to_sym,
          precursor_tool: hash.fetch('precursor_tool'), subject_tool: hash.fetch('subject_tool'),
          support: hash.fetch('support'), trials: hash.fetch('trials'),
          confidence: hash.fetch('confidence'), statement: hash.fetch('statement'),
          generator_principal: hash.fetch('generator_principal')
        )
      end

      def load_provenance(hash)
        Improvement::Provenance.new(**hash.transform_keys(&:to_sym))
      end
    end
  end
end
