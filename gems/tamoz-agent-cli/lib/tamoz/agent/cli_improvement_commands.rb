# frozen_string_literal: true

require "optparse"

module Tamoz
  module Agent
    # `tamoz improve` — the operator entry point onto `tamoz-agent-improvement`.
    #
    # ADR-023: self-improvement is candidate generation, never live self-mutation.
    # This command runs ONLY the deterministic, provider-free, read-only generation
    # half over an operator-supplied trajectory corpus and prints the single
    # candidate heuristic (or none). It never promotes: promotion requires a
    # distinct holdout, immutable provenance, and a human gate, which are separate
    # operator steps by design.
    module CLIImprovementCommands
      # `tamoz improve --corpus DIR [--principal ID] [--json]`, or
      # `tamoz improve promote --bundle FILE --approval human:<actor> [--actor ID]`.
      def cmd_improve(options, argv)
        argv = Array(argv)
        return cmd_improve_promote(options, argv.drop(1)) if argv.first == "promote"

        corpus, principal, as_json = parse_improve_options(argv, options)
        unless corpus && Dir.exist?(corpus)
          @err.puts "improve: --corpus DIR is required and must exist"
          return 2
        end

        root = File.realpath(corpus)
        # Read-only by construction: the generator refuses a mutation capability.
        toolbox = Toolbox.new(root:, allow_changes: false)
        trajectory_paths = Dir.children(root).select { |name| name.end_with?(".json") }.sort
        if trajectory_paths.empty?
          @out.puts "improve: no *.json trajectories found in #{corpus}"
          return 0
        end

        generator = Improvement::Generator.new(toolbox:, principal:)
        candidate = generator.generate(trajectory_paths:)
        render_candidate(candidate, corpus:, count: trajectory_paths.length, as_json:)
        0
      rescue Improvement::ImprovementError, Tamoz::Tools::ToolError => error
        @err.puts "improve: #{error.class.name.split("::").last}: #{error.message}"
        1
      end

      # Record the durable, human-gated promotion of a vetted candidate bundle
      # (the artifact the improvement pipeline produces). ADR-023: this records a
      # transition that activates at the next thread's first intake — it never
      # touches an in-flight thread — and every gate is the gem's own: the sealed
      # report must verify and resolve, the candidate cannot self-promote, the
      # human gate must be present, the holdout must pass, and the provenance must
      # be complete. This command supplies operator artifacts; it weakens nothing.
      def cmd_improve_promote(options, argv)
        bundle_path, approval, actor = parse_promote_options(argv)
        unless bundle_path && File.exist?(bundle_path)
          @err.puts "improve promote: --bundle FILE is required and must exist"
          return 2
        end
        unless approval.to_s.start_with?("human:")
          @err.puts 'improve promote: --approval "human:<actor>" is required'
          return 2
        end

        bundle = JSON.parse(File.read(bundle_path))
        candidate = load_candidate(bundle.fetch("candidate"))
        provenance = load_provenance(bundle.fetch("provenance"))
        report = bundle.fetch("report")
        body = Improvement::EvaluationReport.verify!(report)
        resolver = ->(seal) { seal == Improvement::EvaluationReport.seal(body) ? report : nil }

        with_worker_runtime(options) do |runtime|
          engine = runtime.memory_engine
          unless engine
            @err.puts "improve promote: memory is not enabled for this runtime"
            next 1
          end
          result = Improvement::Promotion.new(engine).promote(
            candidate:, provenance:, report:, human_gate_evidence: approval,
            actor: actor || "operator", evidence_resolver: resolver
          )
          transition = result.fetch("transition")
          state = result.fetch("activated") ? "activated" : "pending activation at the next thread's first intake"
          @out.puts "improve promote: recorded #{transition.transition_id} (#{state})."
          0
        end
      rescue KeyError => error
        @err.puts "improve promote: malformed bundle (missing #{error.message})"
        2
      rescue Improvement::ImprovementError => error
        @err.puts "improve promote: refused — #{error.class.name.split("::").last}: #{error.message}"
        1
      end

      private

      def parse_promote_options(argv)
        bundle = nil
        approval = nil
        actor = nil
        OptionParser.new do |value|
          value.banner = "Usage: tamoz improve promote --bundle FILE --approval human:<actor> [--actor ID]"
          value.on("--bundle FILE", "The vetted candidate bundle from the improvement pipeline") { |path| bundle = path }
          value.on("--approval EVIDENCE", "Human approval, e.g. human:operator-1") { |evidence| approval = evidence }
          value.on("--actor ID", "The promoting principal (default: operator)") { |id| actor = id }
        end.parse!(Array(argv).dup)
        [bundle, approval, actor]
      end

      def load_candidate(hash)
        Improvement::Heuristic.new(
          heuristic_id: hash.fetch("heuristic_id"), surface: hash.fetch("surface").to_sym,
          precursor_tool: hash.fetch("precursor_tool"), subject_tool: hash.fetch("subject_tool"),
          support: hash.fetch("support"), trials: hash.fetch("trials"),
          confidence: hash.fetch("confidence"), statement: hash.fetch("statement"),
          generator_principal: hash.fetch("generator_principal")
        )
      end

      def load_provenance(hash)
        Improvement::Provenance.new(**hash.transform_keys(&:to_sym))
      end

      def parse_improve_options(argv, options)
        corpus = nil
        principal = "operator:cli"
        as_json = false
        OptionParser.new do |value|
          value.banner = "Usage: tamoz improve --corpus DIR [--principal ID] [--json]"
          accept_json(value, options) if respond_to?(:accept_json, true)
          value.on("--corpus DIR", "Directory of verified trajectory JSON files") { |dir| corpus = dir }
          value.on("--principal ID", "Generating principal identity") { |id| principal = id }
          value.on("--json", "Emit the candidate as JSON") { as_json = true }
        end.parse!(Array(argv).dup)
        [corpus, principal, as_json]
      end

      def render_candidate(candidate, corpus:, count:, as_json:)
        if candidate.nil?
          message = "No candidate: #{count} trajectories in #{corpus} do not clear the evidence floor."
          @out.puts(as_json ? JSON.generate("candidate" => nil, "reason" => message) : message)
          return
        end

        if as_json
          @out.puts JSON.generate("candidate" => candidate.to_h)
        else
          @out.puts "Candidate heuristic (not promoted — human gate required, ADR-023):"
          candidate.to_h.each { |key, value| @out.puts "  #{key}: #{value}" }
        end
      end
    end
  end
end
