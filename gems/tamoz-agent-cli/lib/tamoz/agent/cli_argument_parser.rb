# frozen_string_literal: true

require 'optparse'
require 'shellwords'

# Tamoz::Agent::CLI::ArgumentParser — argv -> [options, subcommand, rest]
# (Q3 slice 3). Owns the OptionParser grammar, the option defaults, the
# --check validation, and the --version/--help terminal flags. Help and
# version text are a stable user-facing contract: byte-identical output.
module Tamoz
  module Agent
    class CLI
      # Turns the CLI's argv into the (options, subcommand, rest) tuple the
      # CLI dispatches on. Terminal flags (--version/--help) write to out and
      # mark the tuple's options so the caller exits cleanly.
      class ArgumentParser
        def initialize(out:, subcommands:)
          @out = out
          @subcommands = subcommands
        end

        # :reek:FeatureEnvy -- argv handling is this class's entire purpose;
        # the "target" the logic would move to is Array itself, which is
        # exactly what OptionParser drives here.
        def parse(argv)
          options = default_options
          grammar(options).order!(argv)

          subcommand = @subcommands.include?(argv.first) ? argv.shift : nil
          [options, subcommand, argv]
        end

        private

        def default_options
          {
            root: Dir.pwd,
            json: false,
            allow_changes: false,
            experimental_routing: false,
            adaptive_routing: false,
            shadow_routing: false,
            non_interactive: false,
            checks: {}
          }
        end

        # A declarative option registry (CODING_STANDARD §6): one value.on per
        # option, homogeneous by construction; the OptionParser API drives the
        # value param — there is nowhere else to move it. Long by design.
        # :reek:TooManyStatements :reek:DuplicateMethodCall :reek:NestedIterators :reek:FeatureEnvy
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/BlockLength
        def grammar(options)
          OptionParser.new do |value|
            value.banner = <<~BANNER
              Usage: tamoz [global-options] [subcommand] [options] [ARGS]
                     tamoz [options] TASK

              Interactive:  ask, resume, continue, list, show, follow-up, redirect,
                            cancel, resolve, profile
              Unattended:   init, queue, worker, status, schedule, approve, observe,
                            trace, improve

              Run 'tamoz <subcommand> --help' for a subcommand's own options.
            BANNER
            value.on('--profile PROFILE', 'Trusted profile path or id (durable sessions)') do |entry|
              options[:profile] = entry
            end
            value.on('--model MODEL', 'OpenAI-compatible model identifier') { |entry| options[:model] = entry }
            value.on('--provider PROVIDER', 'Model provider (default: openai)') do |entry|
              options[:provider] = entry
            end
            value.on('--root PATH', 'Workspace root (default: current directory)') do |entry|
              options[:root] = entry
            end
            value.on('--session-dir PATH', 'Durable session directory') do |entry|
              options[:session_dir] = entry
            end
            value.on('--runtime-dir PATH', 'Operator runtime directory (worker, queue, schedule)') do |entry|
              options[:runtime_dir] = entry
            end
            value.on('--session NAME', 'Thread name (default: generated)') do |entry|
              options[:session] = entry
            end
            value.on('--allow-changes', 'Enable reviewed and approved workspace changes') do
              options[:allow_changes] = true
            end
            value.on('--experimental-routing', 'Use the experimental fused request router') do
              options[:experimental_routing] = true
            end
            value.on('--adaptive-routing', 'Use the bounded adaptive read-only session graph') do
              options[:adaptive_routing] = true
            end
            value.on('--work-routing', 'Serve worker and chat turns with the tool-calling work loop') do
              options[:work_routing] = true
            end
            value.on('--shadow-routing', 'Record routing decisions while using the standard workflow') do
              options[:shadow_routing] = true
            end
            value.on('--guidance FILE', 'Project guidance file for tamoz code, e.g. AGENTS.md (repeatable)') do |entry|
              (options[:guidance] ||= []) << entry
            end
            value.on('--check NAME=COMMAND', 'Configure a named verification command') do |entry|
              register_check(options, entry)
            end
            value.on('--json', 'Emit newline-delimited JSON events') { options[:json] = true }
            value.on('--non-interactive', 'Fail instead of prompting') { options[:non_interactive] = true }
            value.on('--version', 'Print the Tamoz version') do
              @out.puts Tamoz::Agent::VERSION
              options[:terminal] = true
            end
            value.on('-h', '--help', 'Show this help') do
              @out.puts value
              options[:terminal] = true
            end
          end
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/BlockLength

        def register_check(options, entry)
          name, command = entry.split('=', 2)
          raise OptionParser::InvalidArgument, 'check must be NAME=COMMAND' if name.to_s.empty? || command.to_s.empty?

          check_argv = Shellwords.split(command)
          raise OptionParser::InvalidArgument, 'check command must not be empty' if check_argv.empty?
          raise OptionParser::InvalidArgument, "duplicate check #{name.inspect}" if options[:checks].key?(name)

          options[:checks][name] = check_argv
        end
      end
    end
  end
end
