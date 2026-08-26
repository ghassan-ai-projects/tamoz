# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Evals
    module Runner
      # Validates caller-owned runner inputs before any benchmark is constructed.
      class InputManifest
        VERSION = 'runner-input-v1'
        FIELDS = %i[
          external_root corpus_definitions scripted_model mcp_server openclaw scenarios
          openclaw_fixture_factory
        ].freeze

        class Invalid < ArgumentError; end

        attr_reader(*FIELDS)

        # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists -- the versioned manifest has a fixed, explicit schema.
        def initialize(external_root:, corpus_definitions:, scripted_model:, mcp_server:, openclaw:,
                       scenarios:, openclaw_fixture_factory: nil, package_roots: [])
          @external_root = validate_root(external_root)
          @corpus_definitions = exact_hash(corpus_definitions, %w[
            agent_memory agent_memory_repository agent_smoke
          ], 'corpus_definitions')
          @scripted_model = exact_hash(scripted_model, %w[adapter responses], 'scripted_model')
          @mcp_server = exact_hash(mcp_server, %w[args path sha256], 'mcp_server')
          @openclaw = exact_hash(openclaw, %w[catalog fixture_factory_loader mission protocol], 'openclaw')
          @scenarios = exact_hash(scenarios, %w[limits registry scenario_definitions sqlite_graph], 'scenarios')
          @openclaw_fixture_factory = openclaw_fixture_factory
          @package_roots = (Array(package_roots) + default_package_roots).uniq.map do |root|
            File.realpath(String(root))
          end.freeze
          validate_documents!
          validate_factory!
          freeze
        rescue TypeError, ArgumentError => e
          raise e if e.is_a?(Invalid)

          raise Invalid, 'runner input manifest is incomplete'
        end
        # rubocop:enable Metrics/AbcSize, Metrics/ParameterLists

        def self.from_path(path, package_root: nil, package_roots: [])
          document = JSON.parse(File.binread(path), create_additions: false)
          new_from_document(document, package_root: package_root, package_roots: package_roots)
        rescue JSON::ParserError
          raise Invalid, 'runner input manifest is invalid'
        rescue Invalid
          raise
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENAMETOOLONG,
               Errno::EINVAL, TypeError, ArgumentError
          raise Tamoz::Evals::ExecutionError, 'runner input manifest is required'
        end

        def self.new_from_document(document, package_root: nil, package_roots: [])
          validate_document_shape!(document)

          roots = package_roots + [package_root].compact
          new(
            external_root: document.fetch('external_root'),
            corpus_definitions: document.fetch('corpus_definitions'),
            scripted_model: document.fetch('scripted_model'),
            mcp_server: document.fetch('mcp_server'),
            openclaw: document.fetch('openclaw'),
            scenarios: document.fetch('scenarios'),
            package_roots: roots
          )
        rescue KeyError, TypeError
          raise Invalid, 'runner input manifest is incomplete'
        end

        # rubocop:disable Lint/UnusedMethodArgument -- labels are part of the diagnostic call contract.
        def path_for(path, label: 'runner input')
          value = String(path)
          unless absolute_path?(value) && File.file?(value)
            raise Invalid,
                  'runner input paths must be explicit and external'
          end

          real_path = File.realpath(value)
          unless under_root?(real_path, @external_root) && @package_roots.none? { |root| under_root?(real_path, root) }
            raise Invalid, 'runner input paths must be explicit and external'
          end

          real_path
        rescue Errno::ENOENT, TypeError, ArgumentError
          raise Invalid, 'runner input paths must be explicit and external'
        end
        # rubocop:enable Lint/UnusedMethodArgument

        def openclaw_fixture!
          return @openclaw_fixture_factory.call if @openclaw_fixture_factory.respond_to?(:call)

          raise Tamoz::Evals::ExecutionError,
                'openclaw benchmark requires an external fixture factory'
        end

        def validate_documents!
          external_documents.each { |label, descriptor| validate_document!(label, descriptor) }
          validate_server!
        end

        def external_documents
          [
            ['corpus_definitions.agent_smoke', @corpus_definitions.fetch('agent_smoke')],
            ['corpus_definitions.agent_memory', @corpus_definitions.fetch('agent_memory')],
            ['corpus_definitions.agent_memory_repository', @corpus_definitions.fetch('agent_memory_repository')],
            ['scripted_model.adapter', @scripted_model.fetch('adapter')],
            ['scripted_model.responses', @scripted_model.fetch('responses')],
            ['openclaw.fixture_factory_loader', @openclaw.fetch('fixture_factory_loader')],
            ['openclaw.protocol', @openclaw.fetch('protocol')],
            ['openclaw.catalog', @openclaw.fetch('catalog')],
            ['openclaw.mission', @openclaw.fetch('mission')],
            ['scenarios.scenario_definitions', @scenarios.fetch('scenario_definitions')],
            ['scenarios.sqlite_graph', @scenarios.fetch('sqlite_graph')],
            ['scenarios.limits', @scenarios.fetch('limits')],
            ['scenarios.registry', @scenarios.fetch('registry')]
          ]
        end

        private

        def self.validate_document_shape!(document)
          unless document.is_a?(Hash) && document['manifest_version'] == VERSION
            raise Invalid, 'runner input manifest is invalid'
          end

          required = %w[corpus_definitions external_root manifest_version mcp_server openclaw scenarios scripted_model]
          raise Invalid, 'runner input manifest is invalid' unless (document.keys - required).empty?
          raise Invalid, 'runner input manifest is incomplete' unless (required - document.keys).empty?
        end

        private_class_method :validate_document_shape!

        def validate_root(root)
          value = String(root)
          unless absolute_path?(value) && File.directory?(value)
            raise Invalid,
                  'runner input paths must be explicit and external'
          end

          File.realpath(value)
        rescue Errno::ENOENT, TypeError, ArgumentError
          raise Invalid, 'runner input paths must be explicit and external'
        end

        def exact_hash(value, keys, label)
          raise Invalid, "#{label} is incomplete" unless value.is_a?(Hash) && value.keys.sort == keys.sort

          value
        end

        def default_package_roots
          roots = []
          roots << PACKAGE_ROOT if defined?(PACKAGE_ROOT)
          roots << Tamoz::Evals::DATA_ROOT if defined?(Tamoz::Evals::DATA_ROOT)
          roots
        end

        def validate_factory!
          return if @openclaw_fixture_factory.nil? || @openclaw_fixture_factory.respond_to?(:call)

          raise Invalid, 'openclaw fixture factory is invalid'
        end

        def validate_document!(label, descriptor)
          unless descriptor.is_a?(Hash) && descriptor.keys.sort == %w[path sha256]
            raise Invalid, "#{label} is incomplete"
          end

          path = path_for(descriptor.fetch('path'), label: label)
          expected = descriptor.fetch('sha256')
          actual = Digest::SHA256.file(path).hexdigest
          raise Invalid, "#{label} digest does not match its manifest" unless expected == actual
        rescue KeyError
          raise Invalid, "#{label} is incomplete"
        end

        def validate_server!
          unless @mcp_server.keys.sort == %w[args path sha256] &&
                 @mcp_server['args'].is_a?(Array) &&
                 @mcp_server['args'].all?(String)
            raise Invalid, 'mcp_server is incomplete'
          end

          validate_document!('mcp_server', @mcp_server.slice('path', 'sha256'))
        rescue KeyError
          raise Invalid, 'mcp_server is incomplete'
        end

        def absolute_path?(path)
          path.is_a?(String) && !path.empty? && File.absolute_path(path) == path
        end

        def under_root?(path, root)
          path == root || path.start_with?("#{root}#{File::SEPARATOR}")
        end
      end
    end
  end
end
