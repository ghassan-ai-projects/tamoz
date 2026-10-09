# frozen_string_literal: true

require 'tamoz/core'
require 'tamoz/comms'
require_relative 'talk/version'
require_relative 'talk/clock'
require_relative 'talk/wav'
require_relative 'talk/inbox'
require_relative 'talk/event_log'
require_relative 'talk/normalizer'
require_relative 'talk/speaker'
require_relative 'talk/transport'
require_relative 'talk/http'
require_relative 'talk/api'
require_relative 'talk/server'
require_relative 'talk/hub'

module Tamoz
  # The browser talk channel: a Tamoz::Comms::Transport over a hardened stdlib HTTP server and the talk page.
  module Talk
  end
end
