# frozen_string_literal: true

require 'json'
require 'tamoz/agent/errors'

module Tamoz
  module Agent
    # Strict readers for a model-written JSON document; refusals raise "<ERROR_PREFIX>/<code>".
    module StrictDocument
      private

      def strict_parse(bytes)
        JSON.parse(bytes, allow_duplicate_key: false)
      rescue JSON::ParserError => e
        code = e.message.include?('duplicate key') ? 'duplicate_key' : 'malformed_json'
        refuse "#{code}: #{e.message}"
      end

      def fetch_array(root, key, max)
        value = root[key]
        refuse "#{key}_not_array" unless value.is_a?(Array)
        refuse "#{key}_too_many: #{value.length}" if value.length > max

        value
      end

      def fetch_bounded_string(hash, key, max)
        refuse "#{key}_missing" unless hash.key?(key)
        value = hash[key]
        refuse "#{key}_not_string" unless value.is_a?(String)
        reject_bad_utf8(value)
        reject_oversize(value.bytesize, key, max)

        value
      end

      def optional_bounded_string(hash, key, max)
        return nil unless hash.key?(key)

        fetch_bounded_string(hash, key, max)
      end

      def reject_unknown_keys(hash, allowed, context)
        unknown = hash.keys - allowed
        refuse "unknown_key: #{context}.#{unknown.first}" unless unknown.empty?
      end

      def reject_oversize(bytesize, what, max)
        refuse "#{what}_too_large: #{bytesize}" if bytesize > max
      end

      # The bytes, not the label: a provider may return valid UTF-8 tagged ASCII-8BIT.
      def reject_bad_utf8(string)
        refuse 'invalid_utf8' unless string.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end

      def refuse(code)
        raise ProtocolError, "#{self::ERROR_PREFIX}/#{code}"
      end
    end
  end
end
