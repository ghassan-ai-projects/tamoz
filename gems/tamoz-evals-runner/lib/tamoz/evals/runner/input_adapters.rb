# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Evals
    module Runner
      # Registry for caller-owned benchmark inputs and factory adapters.
      # rubocop:disable Metrics/ModuleLength -- one boundary owns all adapter registrations.
      module InputAdapters
        class << self
          attr_accessor :openclaw_fixture_factory, :comms_runner_factory, :scripted_model_factory,
                        :scorecard_factory, :treatment_factory,
                        :scripted_model_script_factory, :scripted_model_responses, :memory_records,
                        :memory_repository_config, :websearch_inputs,
                        :mcp_server_inputs, :security_inputs, :skill_body,
                        :scenario_definitions, :skill_impostor_body,
                        :scripted_model_child_source, :subprocess_lib_paths,
                        :scheduler_graph_factory
        end

        module_function

        def register_openclaw_fixture_factory!(factory)
          unless factory.respond_to?(:call)
            raise Tamoz::Evals::ExecutionError, 'openclaw benchmark requires an external fixture factory'
          end

          self.openclaw_fixture_factory = factory
        end

        def load_openclaw_fixture_factory!(path:, sha256:, package_roots: [])
          self.openclaw_fixture_factory = nil
          self.comms_runner_factory = nil
          value = File.realpath(String(path))
          roots = external_package_roots(package_roots)
          unless File.file?(value) && roots.none? { |root| value == root || value.start_with?("#{root}#{File::SEPARATOR}") }
            raise Tamoz::Evals::ExecutionError, 'openclaw benchmark requires an external fixture factory'
          end
          unless Digest::SHA256.file(value).hexdigest == sha256
            raise Tamoz::Evals::ExecutionError, 'openclaw benchmark requires an external fixture factory'
          end

          load value
          return if openclaw_fixture_factory.respond_to?(:call)

          raise Tamoz::Evals::ExecutionError, 'openclaw benchmark requires an external fixture factory'
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENAMETOOLONG,
               Errno::EINVAL, TypeError, ArgumentError
          raise Tamoz::Evals::ExecutionError, 'openclaw benchmark requires an external fixture factory'
        end

        def load_scripted_model_adapter!(path:, sha256:, package_roots: [])
          self.scripted_model_factory = nil
          load_external_file!(
            path:, sha256:, package_roots:,
            message: 'runner scripted model adapter is unavailable'
          )
          return if scripted_model_factory.respond_to?(:call)

          raise Tamoz::Evals::ExecutionError,
                'runner scripted model adapter is unavailable'
        end

        def load_scripted_model_responses!(path:, sha256:, package_roots: [])
          self.scripted_model_responses = nil
          value = external_file!(path:, sha256:, package_roots:,
                                 message: 'runner scripted model responses are unavailable')
          responses = JSON.parse(File.binread(value), create_additions: false)
          unless responses.is_a?(Hash)
            raise Tamoz::Evals::ExecutionError,
                  'runner scripted model responses are unavailable'
          end

          self.scripted_model_responses = responses.freeze
        rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, Errno::EISDIR,
               Errno::ENAMETOOLONG, Errno::EINVAL, TypeError, ArgumentError
          raise Tamoz::Evals::ExecutionError, 'runner scripted model responses are unavailable'
        end

        def openclaw_fixture!
          factory = openclaw_fixture_factory
          return factory.call if factory.respond_to?(:call)

          raise Tamoz::Evals::ExecutionError, 'openclaw benchmark requires an external fixture factory'
        end

        def required_value!(name, message)
          value = public_send(name)
          return value unless value.nil?

          raise Tamoz::Evals::ExecutionError, message
        end

        def load_scenario_definitions!(path:, sha256:, package_roots: [])
          load_external_file!(
            path:, sha256:, package_roots:,
            message: 'scenario definitions are unavailable'
          )
          return if scenario_definitions.is_a?(Hash) && !scenario_definitions.empty?

          raise Tamoz::Evals::ExecutionError, 'scenario definitions are unavailable'
        end

        def load_external_file!(path:, sha256:, package_roots:, message:)
          value = external_file!(path:, sha256:, package_roots:, message:)
          load value
        end

        def external_file!(path:, sha256:, package_roots:, message:)
          value = File.realpath(String(path))
          roots = external_package_roots(package_roots)
          unless File.file?(value) && roots.none? do |root|
                   value == root || value.start_with?("#{root}#{File::SEPARATOR}")
                 end
            raise Tamoz::Evals::ExecutionError, message
          end
          raise Tamoz::Evals::ExecutionError, message unless Digest::SHA256.file(value).hexdigest == sha256

          value
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENAMETOOLONG,
               Errno::EINVAL, TypeError, ArgumentError
          raise Tamoz::Evals::ExecutionError, message
        end

        def external_package_roots(package_roots)
          roots = Array(package_roots)
          roots << PACKAGE_ROOT if defined?(PACKAGE_ROOT)
          roots << Tamoz::Evals::DATA_ROOT if defined?(Tamoz::Evals::DATA_ROOT)
          roots.uniq.map { |root| File.realpath(String(root)) }
        end
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
