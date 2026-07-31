# frozen_string_literal: true

require "json"
require "optparse"

module Tamoz
  module Agent
    class CLI
      USAGE_ERROR = 64

      def self.run(argv = ARGV, out: $stdout, err: $stderr, env: ENV)
        new(out:, err:, env:).run(argv)
      end

      def initialize(out:, err:, env:)
        @out = out
        @err = err
        @env = env
      end

      def run(argv)
        options = parse(argv)
        return 0 if options[:terminal]

        task = argv.join(" ").strip
        raise OptionParser::MissingArgument, "TASK" if task.empty?
        model_name = options[:model] || @env["TAMOZ_MODEL"]
        raise OptionParser::MissingArgument, "--model or TAMOZ_MODEL" if model_name.to_s.empty?

        provider = options[:provider] || @env.fetch("TAMOZ_PROVIDER", "openai")
        provider_key = RubyLLMModel::ENV_KEYS[provider.downcase.to_sym]
        api_key = provider_key && @env[provider_key]
        api_base = @env["#{provider.upcase}_API_BASE"]
        model = RubyLLMModel.new(
          model: model_name,
          provider:,
          api_key:,
          api_base:,
          assume_model_exists: options[:assume_model_exists]
        )
        runtime = Tamoz::Agent.build(model:, root: options[:root])
        result = runtime.run(task) { |event| render(event, json: options[:json]) }
        unless options[:json]
          @out.puts
          @out.puts result.answer
          @out.puts("\nVerification: #{result.satisfied ? "satisfied" : "not satisfied"}")
        end
        result.satisfied ? 0 : 2
      rescue OptionParser::ParseError, ArgumentError => error
        @err.puts "tamoz: #{error.message}"
        @err.puts "Try 'tamoz --help'."
        USAGE_ERROR
      rescue Tamoz::Agent::Error => error
        @err.puts "tamoz: #{error.message}"
        1
      end

      private

      def parse(argv)
        options = {root: Dir.pwd, json: false, assume_model_exists: false}
        parser = OptionParser.new do |value|
          value.banner = "Usage: tamoz [options] TASK"
          value.on("--model MODEL", "RubyLLM model identifier") { |entry| options[:model] = entry }
          value.on("--provider PROVIDER", "RubyLLM provider (default: openai)") do |entry|
            options[:provider] = entry
          end
          value.on("--root PATH", "Read-only workspace root (default: current directory)") do |entry|
            options[:root] = entry
          end
          value.on("--assume-model-exists", "Allow an unlisted model at a custom endpoint") do
            options[:assume_model_exists] = true
          end
          value.on("--json", "Emit newline-delimited JSON events") { options[:json] = true }
          value.on("--version", "Print the Tamoz version") do
            @out.puts Tamoz::Agent::VERSION
            options[:terminal] = true
          end
          value.on("-h", "--help", "Show this help") do
            @out.puts value
            options[:terminal] = true
          end
        end
        parser.parse!(argv)
        options
      end

      def render(event, json:)
        if json
          @out.puts JSON.generate("type" => event.type.to_s, "data" => event.data)
          return
        end

        case event.type
        when :plan_drafted
          @out.puts "Plan #{event.data.fetch("attempt")}:"
          event.data.fetch("plan").fetch("steps").each do |step|
            tool = step.fetch("tool") ? " [#{step.fetch("tool")}]" : ""
            @out.puts "  - #{step.fetch("purpose")}#{tool}"
          end
        when :plan_reviewed
          @out.puts "Review (#{event.data.fetch("layer")}): #{event.data.fetch("decision")}"
        when :tool_started
          @out.puts "Running #{event.data.fetch("tool")}..."
        end
      end
    end
  end
end
