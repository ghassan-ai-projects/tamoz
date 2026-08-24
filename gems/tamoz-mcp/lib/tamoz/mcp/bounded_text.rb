# frozen_string_literal: true

module Tamoz
  module Mcp
    # Bounds one untrusted display string: forces UTF-8, scrubs invalid
    # encoding, strips control characters, and truncates to a byte budget
    # without splitting a UTF-8 sequence. Shared by the catalog's entry
    # descriptions and the elicitation interrupt's id/message/schema fields —
    # both bound server-supplied text before it can reach a prompt or a
    # durable record, differing only in which budget applies.
    module BoundedText
      module_function

      def bound(value, max_bytes)
        normalize_to_utf8(value)
          .then { |text| sanitize_controls(text) }
          .then { |text| truncate_to_byte_budget(text, max_bytes) }
          .freeze
      end

      private

      def normalize_to_utf8(value)
        text = String(value || "").dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub("")
      end

      def sanitize_controls(text)
        text.gsub(CONTROL_CHARACTER_PATTERN, " ").strip
      end

      def truncate_to_byte_budget(text, max_bytes)
        return text if text.bytesize <= max_bytes

        text.byteslice(0, max_bytes).scrub("").rstrip
      end
    end
  end
end
