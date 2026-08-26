# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Loads only the selected provider's credentials from an operator env file.
      class EnvironmentLoader
        RUNTIME_ENVIRONMENT_KEYS = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH].freeze

        def self.for(provider:, env_file:, environment: nil)
          environment ||= safe_process_environment(provider)
          new(provider:, env_file:, environment:).call
        end

        def self.safe_process_environment(provider)
          keys = RUNTIME_ENVIRONMENT_KEYS + Tamoz::Agent::ModelClientFactory.environment_names(provider:)
          ENV.slice(*keys)
        end
        private_class_method :safe_process_environment

        def initialize(provider:, env_file:, environment:)
          @provider = String(provider).downcase.to_sym
          @env_file = env_file.to_s
          @environment = environment.to_h.transform_keys(&:to_s)
        end

        def call
          return @environment.dup unless File.file?(@env_file)

          loaded = @environment.dup
          dotenv_values.each do |name, value|
            loaded[name] = value unless loaded.key?(name)
          end
          loaded
        end

        private

        def dotenv_values
          values = {}
          File.foreach(@env_file) do |line|
            name, value = parse_line(line)
            next unless provider_environment_names.include?(name)
            next if values.key?(name)

            values[name] = value
          end
          values
        end

        def parse_line(line)
          return [nil, nil] if line.strip.empty? || line.lstrip.start_with?('#')

          name, value = line.split(/\s*=\s*/, 2)
          return [nil, nil] if name.to_s.strip.empty? || value.nil?

          name = name.strip.sub(/\Aexport\s+/, '')
          value = value.strip
          value = value[1..-2] if value.match?(/\A(['"]).*\1\z/)
          [name, value]
        end

        def provider_environment_names
          Tamoz::Agent::ModelClientFactory.environment_names(provider: @provider)
        rescue Tamoz::Agent::ModelCallError
          raise ArgumentError, "unsupported benchmark provider #{@provider.inspect}"
        end
      end
    end
  end
end
