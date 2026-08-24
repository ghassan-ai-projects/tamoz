# frozen_string_literal: true

module Tamoz
  module Telegram
    # The Bot API response exceeded the configured transport byte cap
    # (`max_response_bytes`). The body is abandoned mid-read, never buffered
    # past the limit; the caller decides what the truncated read means for
    # its seam (a poll is transient weather, a send is ambiguity).
    class ResponseTooLargeError < Tamoz::Error
      CATEGORY = "telegram_response_too_large"
      SAFE_MESSAGE = "The Telegram API response exceeded the configured transport limit."
    end
  end
end
