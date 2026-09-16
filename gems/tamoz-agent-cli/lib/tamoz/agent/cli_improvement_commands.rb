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
      # `tamoz improve --corpus DIR [--principal ID] [--json]`
      def cmd_improve(options, argv)
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

      private

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
