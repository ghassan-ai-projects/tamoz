# frozen_string_literal: true

require 'tamoz/core'
require_relative 'comms/version'
require_relative 'comms/errors'
require_relative 'comms/canonical'
require_relative 'comms/interrupt_digest'
require_relative 'comms/decision_record'
require_relative 'comms/decision_store'

module Tamoz
  # Communication channels (ADR-041): one contract gem owning the channel
  # vocabulary and seams — values, identity and admission policy, rendering,
  # the Transport adapter contract, and the structural CommsStore contract —
  # with each transport shipped as its own adapter gem. This gem depends only
  # on tamoz-core and never opens a socket; the gateway process holds the
  # transport credential, not the worker (ADR-042).
  module Comms
  end
end
