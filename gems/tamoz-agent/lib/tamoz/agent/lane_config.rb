# frozen_string_literal: true

module Tamoz
  module Agent
    # Declared lane → model-tier mapping (PLAN_TAMOZ_STREAM_BUILD T0.5, §6.3).
    # The episode worker selects the model for a lane from this config — never
    # by inference, and never by a hidden default. A lane without a declared
    # model refuses to run.
    #
    # "fast uses the cheap tier, deep the strong tier" is the operator's
    # declaration: the config maps each lane to a RubyLLM model identifier, and
    # the worker uses exactly what was declared.
    class LaneConfig
      LANES = %w[fast deep batch].freeze

      def self.build(map)
        unless map.is_a?(Hash)
          raise ConfigurationError, "lane model map must be an object"
        end
        missing = LANES - map.keys.map(&:to_s)
        unless missing.empty?
          raise ConfigurationError,
                "lane model map must declare every lane; missing: #{missing.join(", ")}"
        end
        unknown = map.keys.map(&:to_s) - LANES
        unless unknown.empty?
          raise ConfigurationError,
                "lane model map declares unknown lanes: #{unknown.join(", ")}"
        end
        normalized = LANES.to_h do |lane|
          model = map[lane] || map[lane.to_sym]
          unless model.is_a?(String) && !model.empty?
            raise ConfigurationError, "lane #{lane} must name a non-empty model identifier"
          end

          [lane, model.dup.freeze]
        end
        new(normalized.freeze)
      end

      private_class_method :new

      def initialize(models)
        @models = models
        freeze
      end

      def lanes
        LANES
      end

      def model_for(lane)
        key = String(lane)
        unless LANES.include?(key)
          raise ConfigurationError,
                "unknown lane #{key.inspect}; lanes are #{LANES.join(", ")}"
        end

        @models.fetch(key)
      end

      def to_h
        @models.dup.freeze
      end
    end
  end
end
