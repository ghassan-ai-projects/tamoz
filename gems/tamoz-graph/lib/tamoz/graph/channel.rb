# frozen_string_literal: true

module Tamoz
  module Graph
    class Channel
      attr_reader :name, :reducer, :default_bytes, :default_name, :default_version, :managed,
                  :immutable

      def initialize(
        name:,
        reducer:,
        default:,
        default_name:,
        default_version:,
        managed:,
        codec:,
        immutable: false
      )
        @name = Identifier.symbol(name, name: "state channel")
        @managed = normalize_managed(managed)
        @immutable = immutable == true
        if @immutable && @managed
          raise GraphDefinitionError, "channel #{@name} cannot be both immutable and managed"
        end
        @default_name = default_name && Identifier.string(default_name, name: "default name")
        @default_version = default_version && Identifier.version(default_version, name: "default version")
        @reducer = managed ? nil : reducer
        if managed && reducer
          raise GraphDefinitionError, "managed channel #{@name} cannot have a reducer"
        end
        if @immutable && reducer
          raise GraphDefinitionError, "immutable channel #{@name} cannot have a reducer"
        end
        @default_bytes = compile_default(
          default,
          default_name:,
          default_version:,
          codec:
        )
        freeze
      end

      def default(codec)
        codec.load(default_bytes)
      end

      def descriptor
        {
          "name" => name.to_s,
          "reducer" => reducer && {"name" => reducer.name, "version" => reducer.version},
          "default" => default_bytes,
          "default_factory" => default_name && {"name" => default_name, "version" => default_version},
          "managed" => managed && "remaining_steps",
          "immutable" => immutable
        }
      end

      def managed?
        !managed.nil?
      end

      def immutable?
        immutable
      end

      private

      def normalize_managed(value)
        return nil if value.nil?
        return Managed::RemainingSteps if value.equal?(Managed::RemainingSteps)

        raise GraphDefinitionError, "unsupported managed channel #{value.inspect}"
      end

      def compile_default(value, default_name:, default_version:, codec:)
        return codec.dump(managed? ? 0 : nil).freeze if value.nil?

        unless value.respond_to?(:call)
          return codec.dump(value).freeze
        end
        unless @default_name && @default_version
          raise GraphDefinitionError,
                "callable default for #{name} requires default_name and default_version"
        end
        first = codec.dump(value.call)
        second = codec.dump(value.call)
        unless first == second
          raise GraphDefinitionError, "callable default for #{name} is not deterministic"
        end

        first.freeze
      rescue Error, ConfigurationError, InvalidUpdateError, GraphDefinitionError
        raise
      rescue StandardError => error
        raise GraphDefinitionError, "default for #{name} failed: #{error.class}"
      end
    end
  end
end
