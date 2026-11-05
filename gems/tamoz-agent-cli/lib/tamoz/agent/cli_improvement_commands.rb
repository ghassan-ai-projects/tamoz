# frozen_string_literal: true

require 'optparse'
require_relative 'cli_improve_promote_commands'

module Tamoz
  module Agent
    # `tamoz improve --corpus DIR [--principal ID] [--json]` (generate), or
    # `tamoz improve promote --bundle FILE --approval human:<actor> [--actor ID]`.
    module CLIImprovementCommands
      include CLIImprovePromoteCommands

      def cmd_improve(options, argv)
        argv = Array(argv)
        return cmd_improve_promote(options, argv.drop(1)) if argv.first == 'promote'

        corpus, principal, as_json = parse_improve_options(argv, options)
        unless corpus && Dir.exist?(corpus)
          @err.puts 'improve: --corpus DIR is required and must exist'
          return 2
        end

        generate_candidate(corpus, principal, as_json)
      rescue Improvement::ImprovementError, Tamoz::Tools::ToolError => e
        @err.puts "improve: #{e.class.name.split('::').last}: #{e.message}"
        1
      end

      private

      def generate_candidate(corpus, principal, as_json)
        root = File.realpath(corpus)
        toolbox = Toolbox.new(root:, allow_changes: false)
        trajectory_paths = Dir.children(root).select { |name| name.end_with?('.json') }.sort
        if trajectory_paths.empty?
          @out.puts "improve: no *.json trajectories found in #{corpus}"
          return 0
        end

        generator = Improvement::Generator.new(toolbox:, principal:)
        candidate = generator.generate(trajectory_paths:)
        render_candidate(candidate, corpus:, count: trajectory_paths.length, as_json:)
        0
      end

      def parse_improve_options(argv, options)
        corpus = nil
        principal = 'operator:cli'
        as_json = false
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz improve --corpus DIR [--principal ID] [--json]'
          accept_json(value, options) if respond_to?(:accept_json, true)
          value.on('--corpus DIR', 'Directory of verified trajectory JSON files') { |dir| corpus = dir }
          value.on('--principal ID', 'Generating principal identity') { |id| principal = id }
          value.on('--json', 'Emit the candidate as JSON') { as_json = true }
        end.parse!(Array(argv).dup)
        [corpus, principal, as_json]
      end

      def render_candidate(candidate, corpus:, count:, as_json:)
        if candidate.nil?
          message = "No candidate: #{count} trajectories in #{corpus} do not clear the evidence floor."
          @out.puts(as_json ? JSON.generate('candidate' => nil, 'reason' => message) : message)
          return
        end

        if as_json
          @out.puts JSON.generate('candidate' => candidate.to_h)
        else
          @out.puts 'Candidate heuristic (not promoted — human gate required, ADR-023):'
          candidate.to_h.each { |key, value| @out.puts "  #{key}: #{value}" }
        end
      end
    end
  end
end
