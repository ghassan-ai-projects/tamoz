# frozen_string_literal: true

module Tamoz
  module Graph
    module Identifier
      PATTERN = /\A[a-zA-Z][a-zA-Z0-9._-]*\z/
      VERSION_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
      IDENTITY_PATTERN = /\A[a-zA-Z][a-zA-Z0-9_.:-]*\z/
      MAX_BYTES = 128

      module_function

      def string(value, name:)
        text = String(value).encode(Encoding::UTF_8)
        raise GraphDefinitionError, "#{name} cannot be empty" if text.empty?
        raise GraphDefinitionError, "#{name} exceeds #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES
        raise GraphDefinitionError, "#{name} must be valid UTF-8" unless text.valid_encoding?
        raise GraphDefinitionError, "#{name} must match #{PATTERN.inspect}" unless PATTERN.match?(text)

        text.dup.freeze
      rescue EncodingError => error
        raise GraphDefinitionError, "#{name} must be valid UTF-8: #{error.message}"
      end

      def symbol(value, name:)
        string(value, name:).to_sym
      end

      def version(value, name:)
        text = String(value).encode(Encoding::UTF_8)
        raise GraphDefinitionError, "#{name} cannot be empty" if text.empty?
        raise GraphDefinitionError, "#{name} exceeds #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES
        raise GraphDefinitionError, "#{name} must be valid UTF-8" unless text.valid_encoding?
        unless VERSION_PATTERN.match?(text)
          raise GraphDefinitionError, "#{name} must match #{VERSION_PATTERN.inspect}"
        end

        text.dup.freeze
      rescue EncodingError => error
        raise GraphDefinitionError, "#{name} must be valid UTF-8: #{error.message}"
      end

      def identity(value, name:)
        text = String(value).encode(Encoding::UTF_8)
        raise GraphDefinitionError, "#{name} cannot be empty" if text.empty?
        raise GraphDefinitionError, "#{name} exceeds #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES
        raise GraphDefinitionError, "#{name} must be valid UTF-8" unless text.valid_encoding?
        unless IDENTITY_PATTERN.match?(text)
          raise GraphDefinitionError, "#{name} must match #{IDENTITY_PATTERN.inspect}"
        end

        text.dup.freeze
      rescue EncodingError => error
        raise GraphDefinitionError, "#{name} must be valid UTF-8: #{error.message}"
      end

      private_constant :PATTERN, :VERSION_PATTERN, :IDENTITY_PATTERN, :MAX_BYTES
    end

    private_constant :Identifier
  end
end
