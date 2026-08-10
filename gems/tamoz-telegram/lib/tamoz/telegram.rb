# frozen_string_literal: true

require 'tamoz/comms'
require_relative 'telegram/version'
require_relative 'telegram/client'
require_relative 'telegram/normalizer'
require_relative 'telegram/transport'

module Tamoz
  # Telegram transport adapter (ADR-041): one gem implementing the
  # Tamoz::Comms::Transport seam over the Telegram Bot API. Depends only on
  # tamoz-comms and the standard library — no HTTP client gem, no framework.
  # All four seam methods are driven against the in-memory fixture server in
  # tests, which can duplicate/reorder/throttle/lose and time out.
  module Telegram
  end
end
