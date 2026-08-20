# frozen_string_literal: true

module Tamoz
  module Observability
    Usage = Data.define(
      :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens
    ) do
      MAX_TOKENS = 1_000_000_000

      def initialize(input_tokens:, output_tokens:, cache_read_tokens:, cache_write_tokens:)
        super(
          input_tokens: validate_tokens(input_tokens, :input_tokens),
          output_tokens: validate_tokens(output_tokens, :output_tokens),
          cache_read_tokens: validate_tokens(cache_read_tokens, :cache_read_tokens),
          cache_write_tokens: validate_tokens(cache_write_tokens, :cache_write_tokens)
        )
      end

      def measured?
        [input_tokens, output_tokens, cache_read_tokens, cache_write_tokens].any? { |value| !value.nil? }
      end

      def to_h
        {
          'input_tokens' => input_tokens,
          'output_tokens' => output_tokens,
          'cache_read_tokens' => cache_read_tokens,
          'cache_write_tokens' => cache_write_tokens
        }.compact
      end

      private

      def validate_tokens(value, name)
        return nil if value.nil?
        return value if value.is_a?(Integer) && value.between?(0, MAX_TOKENS)

        raise ValidationError, "#{name} must be an integer between 0 and #{MAX_TOKENS}"
      end
    end

    Cost = Data.define(:value, :currency, :basis, :pricing_source, :pricing_version) do
      BASES = %i[measured estimated].freeze

      def initialize(value:, currency:, basis:, pricing_source:, pricing_version:)
        value = Float(value)
        raise ValidationError, 'cost value must be finite and non-negative' unless value.finite? && value >= 0
        raise ValidationError, 'cost basis must be measured or estimated' unless BASES.include?(basis.to_sym)

        super(value:, currency: String(currency).freeze, basis: basis.to_sym,
              pricing_source: String(pricing_source).freeze, pricing_version: String(pricing_version).freeze)
      end

      def to_h
        {
          'value' => value,
          'currency' => currency,
          'basis' => basis.to_s,
          'pricing_source' => pricing_source,
          'pricing_version' => pricing_version
        }
      end
    end

    class PricingTable
      DIGEST_DOMAIN = "tamoz.observability.pricing_table.v1\n"

      attr_reader :source, :version, :digest

      def initialize(source:, version:, input_per_million:, output_per_million:)
        @source = String(source).freeze
        @version = String(version).freeze
        raise ValidationError, 'pricing source must not be empty' if @source.empty?
        raise ValidationError, 'pricing version must not be empty' if @version.empty?
        @input = non_negative(input_per_million, :input_per_million)
        @output = non_negative(output_per_million, :output_per_million)
        @digest = Tamoz::Core.digest(DIGEST_DOMAIN, to_h)
        freeze
      end

      def cost(usage, currency: 'USD')
        return nil unless usage.is_a?(Usage)
        return nil unless usage.input_tokens && usage.output_tokens

        Cost.new(
          value: ((usage.input_tokens * @input) + (usage.output_tokens * @output)) / 1_000_000.0,
          currency:, basis: :estimated, pricing_source: source, pricing_version: version
        )
      end

      def to_h
        {
          'source' => source,
          'version' => version,
          'input_per_million' => @input,
          'output_per_million' => @output
        }
      end

      private

      def non_negative(value, name)
        value = Float(value)
        return value if value.finite? && value >= 0

        raise ValidationError, "#{name} must be finite and non-negative"
      end
    end
  end
end
