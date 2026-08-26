# frozen_string_literal: true

require 'tamoz/core'
require_relative 'comms/version'
require_relative 'comms/errors'
require_relative 'comms/lifecycle'
require_relative 'comms/canonical'
require_relative 'comms/shapes'
require_relative 'comms/interrupt_digest'
require_relative 'comms/decision_record'
require_relative 'comms/decision_store'
require_relative 'comms/authority_evidence'
require_relative 'comms/surface_descriptor'
require_relative 'comms/inbound_envelope'
require_relative 'comms/delivery'
require_relative 'comms/binding'
require_relative 'comms/approval_prompt'
require_relative 'comms/commands'
require_relative 'comms/control_reply'
require_relative 'comms/admission'
require_relative 'comms/pairing_challenge'
require_relative 'comms/rendering'
require_relative 'comms/transport'
require_relative 'comms/delivery_sink'
require_relative 'comms/comms_store'
require_relative 'comms/outbox_delivery_sink'

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
