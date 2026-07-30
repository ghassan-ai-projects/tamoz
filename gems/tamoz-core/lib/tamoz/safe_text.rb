# frozen_string_literal: true

module Tamoz
  module SafeText
    CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u

    module_function

    def normalize(value, name:, max_bytes:, error_class:, pattern: nil)
      string = String(value)
      utf8 = string.encode(Encoding::UTF_8)
      raise error_class, "#{name} cannot be empty" if utf8.empty?
      raise error_class, "#{name} exceeds #{max_bytes} bytes" if utf8.bytesize > max_bytes
      raise error_class, "#{name} must be valid UTF-8" unless utf8.valid_encoding?
      raise error_class, "#{name} cannot contain control characters" if CONTROL_CHARACTERS.match?(utf8)
      if pattern && !pattern.match?(utf8)
        raise error_class, "#{name} must match #{pattern.inspect}"
      end

      utf8.dup.freeze
    rescue EncodingError => error
      raise error_class, "#{name} must be valid UTF-8: #{error.message}"
    end

    private_constant :CONTROL_CHARACTERS
  end

  private_constant :SafeText
end
