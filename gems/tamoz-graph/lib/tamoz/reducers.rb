# frozen_string_literal: true

module Tamoz
  module Reducers
    Reducer = Data.define(:name, :version, :callable) do
      def initialize(name:, version:, callable:)
        raise GraphDefinitionError, "reducer callable must respond to call" unless callable.respond_to?(:call)

        super(
          name: Graph.const_get(:Identifier, false).string(name, name: "reducer name"),
          version: Graph.const_get(:Identifier, false).version(version, name: "reducer version"),
          callable:
        )
      end

      def call(current, writes)
        callable.call(current, writes)
      end
    end

    APPEND = Reducer.new(
      name: "append",
      version: "1",
      callable: lambda do |current, writes|
        unless current.is_a?(Array) && writes.all? { |write| write.is_a?(Array) }
          raise InvalidUpdateError, "append reducer requires Array current value and writes"
        end

        current + writes.flatten(1)
      end
    )
    MERGE = Reducer.new(
      name: "merge",
      version: "1",
      callable: lambda do |current, writes|
        unless current.is_a?(Hash) && writes.all? { |write| write.is_a?(Hash) }
          raise InvalidUpdateError, "merge reducer requires Hash current value and writes"
        end

        writes.reduce(current) { |result, write| result.merge(write) }
      end
    )
    UNION = Reducer.new(
      name: "union",
      version: "1",
      callable: lambda do |current, writes|
        unless current.is_a?(Array) && writes.all? { |write| write.is_a?(Array) }
          raise InvalidUpdateError, "union reducer requires Array current value and writes"
        end

        (current + writes.flatten(1)).each_with_object([]) do |entry, result|
          result << entry unless result.include?(entry)
        end
      end
    )
    MAX = Reducer.new(
      name: "max",
      version: "1",
      callable: ->(current, writes) { [current, *writes].compact.max }
    )
    MIN = Reducer.new(
      name: "min",
      version: "1",
      callable: ->(current, writes) { [current, *writes].compact.min }
    )
    BUILT_INS = {
      append: APPEND,
      merge: MERGE,
      union: UNION,
      max: MAX,
      min: MIN
    }.freeze

    module_function

    def append = APPEND
    def merge = MERGE
    def union = UNION
    def max = MAX
    def min = MIN

    def resolve(value, name: nil, version: nil)
      return nil if value.nil?
      return value if value.is_a?(Reducer)
      return BUILT_INS.fetch(value) if value.is_a?(Symbol) && BUILT_INS.key?(value)

      unless value.respond_to?(:call) && name && version
        raise GraphDefinitionError,
              "custom reducer requires reducer_name and reducer_version"
      end

      Reducer.new(name:, version:, callable: value)
    end

    private_constant :BUILT_INS
  end
end
