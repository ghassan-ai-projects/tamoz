# frozen_string_literal: true

require 'uri'

module Tamoz
  module Research
    # Text rules every part shares: whitespace-insensitive matching and bounded strings.
    module Text
      module_function

      def squash(text) = String(text).gsub(/[[:space:]]+/, ' ').strip

      def contains?(haystack, needle) = squash(haystack).downcase.include?(squash(needle).downcase)

      # :reek:LongParameterList -- a name and two bounds are the check.
      def bounded(value, name, max:, min: 1)
        text = value.is_a?(String) ? squash(value) : ''
        return text if text.length.between?(min, max)

        raise Error, "#{name} must be text of #{min} to #{max} characters"
      end

      def host(url)
        URI.parse(String(url)).host.to_s.downcase.delete_prefix('www.')
      rescue URI::InvalidURIError
        ''
      end
    end
  end
end
