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
        text = String(value || "").dup.force_encoding(Encoding::UTF_8)
        text = text.scrub("") unless text.valid_encoding?
        text = text.gsub(CONTROL_CHARACTER_PATTERN, " ").strip
        if text.bytesize > max_bytes
          text = text.byteslice(0, max_bytes).scrub("").rstrip
        end
        text.freeze
      end
    end
  end
end
