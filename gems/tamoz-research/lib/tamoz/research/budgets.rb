# frozen_string_literal: true

require 'json'

module Tamoz
  module Research
    # How much one research run may spend: operator ceilings, and the defaults for each depth.
    # :reek:DataClump :reek:FeatureEnvy :reek:TooManyStatements :reek:NilCheck :reek:NestedIterators
    # -- validation reads the document it checks, field by field.
    class Budgets
      FILE = File.expand_path('../../../data/research_budgets.json', __dir__)
      LIMITS = %w[children_per_wave waves searches page_reads].freeze
      CEILINGS = (LIMITS + %w[children_per_run]).freeze

      # One depth's defaults; `words` is the report's target length as [low, high].
      Depth = Data.define(:name, :children_per_wave, :waves, :searches, :page_reads, :minutes, :words)

      attr_reader :ceilings, :depths

      def self.shipped = @shipped ||= parse(File.read(FILE, encoding: Encoding::UTF_8))

      def self.parse(text)
        new(JSON.parse(text, allow_duplicate_key: false))
      rescue JSON::ParserError
        raise Error, 'research budgets are not valid JSON'
      end

      def initialize(document)
        raise Error, 'research budgets must be an object with ceilings and depths' unless
          document.is_a?(Hash) && document.keys.sort == %w[ceilings depths]

        @ceilings = CEILINGS.to_h { |key| [key, positive(document.fetch('ceilings'), key, 'ceilings')] }.freeze
        @depths = parse_depths(document.fetch('depths'))
        freeze
      end

      def depth(name) = @depths.fetch(String(name)) { raise Error, "unknown depth #{name.inspect}" }

      def depth_names = @depths.keys

      # A narrower copy: `override` may lower a ceiling or a depth's number, never raise one.
      def narrowed(override)
        document = to_h
        merge_lower(document, override, [])
        ceilings = document.fetch('ceilings')
        document.fetch('depths').each_value do |depth|
          LIMITS.each { |key| depth[key] = [depth.fetch(key), ceilings.fetch(key)].min }
        end
        self.class.new(document)
      end

      def to_h
        { 'ceilings' => @ceilings.dup,
          'depths' => @depths.transform_values { |depth| depth.to_h.except(:name).transform_keys(&:to_s) } }
      end

      private

      def parse_depths(depths)
        raise Error, 'depths must be an object' unless depths.is_a?(Hash) && !depths.empty?

        depths.to_h { |name, fields| [name, build_depth(name, fields)] }.freeze
      end

      def build_depth(name, fields)
        raise Error, "depth #{name} must be an object" unless fields.is_a?(Hash)

        limits = LIMITS.to_h { |key| [key.to_sym, within_ceiling(fields, key, name)] }
        Depth.new(name:, minutes: positive(fields, 'minutes', name), words: words(fields, name), **limits)
      end

      def within_ceiling(fields, key, name)
        value = positive(fields, key, name)
        ceiling = @ceilings.fetch(key)
        raise Error, "depth #{name}: #{key} #{value} is above the ceiling #{ceiling}" if value > ceiling

        value
      end

      def words(fields, name)
        pair = fields['words']
        low, high = pair
        return [low, high].freeze if pair.is_a?(Array) && pair.length == 2 && pair.all?(Integer) &&
                                     low.positive? && low <= high

        raise Error, "depth #{name}: words must be [low, high]"
      end

      def positive(fields, key, where)
        value = fields[key]
        return value if value.is_a?(Integer) && value.positive?

        raise Error, "#{where}: #{key} must be a positive integer"
      end

      def merge_lower(document, override, path)
        raise Error, "override at #{path.join('.')} must be an object" unless override.is_a?(Hash)

        override.each do |key, value|
          target = document[key]
          where = path + [key]
          raise Error, "override names unknown #{where.join('.')}" if target.nil?
          next merge_lower(target, value, where) if target.is_a?(Hash)

          document[key] = lower(target, value, where)
        end
      end

      def lower(current, value, path)
        return value if value.is_a?(Integer) && value.positive? && current.is_a?(Integer) && value <= current

        raise Error, "override may only lower #{path.join('.')} (#{current} → #{value.inspect})"
      end
    end
  end
end
