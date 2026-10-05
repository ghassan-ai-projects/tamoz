# frozen_string_literal: true

require 'yaml'

module Tamoz
  module Observability
    module Diagnosis
      # The digest-pinned rule set a diagnosis runs; every threshold and word lives in the YAML.
      class Rules
        DEFAULT_PATH = File.expand_path('../../../../diagnosis/rules.yaml', __dir__)
        DIGEST_DOMAIN = "tamoz.observability.diagnosis.rules\n"
        PARAMETERS = {
          'status' => %w[kind field values],
          'age' => %w[kind field values time_field older_than_minutes],
          'failure_rate' => %w[kind operation_prefix settled_values failed_values time_field min_count
                               max_failure_ratio],
          'failure_groups' => %w[kind field values time_field min_count],
          'journal_events' => %w[names min_count],
          'telemetry_loss' => %w[min_count]
        }.freeze
        DETECTORS = PARAMETERS.keys.freeze
        RECORD_DETECTORS = %w[status age failure_rate failure_groups].freeze
        REQUIRED = %w[id detector severity category title action].freeze

        Rule = Data.define(:id, :detector, :severity, :category, :title, :action, :parameters) do
          def kind = parameters['kind']
          def field = parameters['field']
          def field_values = parameters['values']
          def missing = Array(parameters['missing'])
          def operation_prefix = parameters['operation_prefix'].to_s
          def time_field = parameters['time_field']
          def older_than_minutes = parameters['older_than_minutes']
          def settled_values = parameters['settled_values']
          def failed_values = parameters['failed_values']
          def max_failure_ratio = parameters['max_failure_ratio']
          def min_count = parameters['min_count']
          def names = parameters['names']
        end

        attr_reader :rules, :digest, :severities

        def self.default = load(DEFAULT_PATH)

        def self.load(path)
          document = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
          new(document)
        rescue Psych::Exception, SystemCallError => e
          raise ValidationError, "diagnosis rules #{path}: #{e.message}"
        end

        def initialize(document)
          raise ValidationError, 'diagnosis rules must be a mapping' unless document.is_a?(Hash)
          raise ValidationError, 'diagnosis rules format_version must be 1' unless document['format_version'] == 1

          @severities = Array(document['severities']).freeze
          @categories = Array(document['categories']).freeze
          @rules = Array(document['rules']).map { |entry| build(entry) }.freeze
          ensure_unique_ids!
          @digest = Tamoz::Core.digest(DIGEST_DOMAIN, document)
          freeze
        end

        def severity_rank(severity) = @severities.index(severity)

        private

        def build(entry)
          raise ValidationError, 'each diagnosis rule must be a mapping' unless entry.is_a?(Hash)

          validate_required!(entry)
          validate_choices!(entry)
          validate_parameters!(entry)

          Rule.new(**entry.slice(*REQUIRED).transform_keys(&:to_sym),
                   parameters: Tamoz::Core.deep_freeze(entry.except(*REQUIRED)))
        end

        def validate_required!(entry)
          missing = REQUIRED.reject { |key| entry[key].is_a?(String) && !entry[key].empty? }
          raise ValidationError, "diagnosis rule #{entry['id']}: missing #{missing.join(', ')}" unless missing.empty?
        end

        def validate_parameters!(entry)
          missing = PARAMETERS.fetch(entry['detector']).select { |key| entry[key].nil? }
          raise ValidationError, "diagnosis rule #{entry['id']}: missing #{missing.join(', ')}" unless missing.empty?
        end

        def validate_choices!(entry)
          id = entry['id']
          raise ValidationError, "diagnosis rule #{id}: unknown detector" unless DETECTORS.include?(entry['detector'])
          raise ValidationError, "diagnosis rule #{id}: unknown severity" unless @severities.include?(entry['severity'])
          raise ValidationError, "diagnosis rule #{id}: unknown category" unless @categories.include?(entry['category'])
          return unless RECORD_DETECTORS.include?(entry['detector'])
          return if TelemetryReader::KINDS.map(&:to_s).include?(entry['kind'])

          raise ValidationError, "diagnosis rule #{id}: unknown record kind #{entry['kind'].inspect}"
        end

        def ensure_unique_ids!
          duplicate = @rules.map(&:id).tally.find { |_id, count| count > 1 }
          raise ValidationError, "diagnosis rule #{duplicate.first} is defined twice" if duplicate
        end
      end
    end
  end
end
