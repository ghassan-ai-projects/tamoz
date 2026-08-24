# frozen_string_literal: true

module Tamoz
  module Core
    # A model document cannot be parsed or fails its shape contract. Homed in
    # tamoz-core next to the parse helpers so the durable-memory consolidation
    # path parses without reaching into the agent; `Tamoz::Agent::ProtocolError`
    # is a constant alias of this class, exactly like the D-7 tool-error family.
    #
    # Messages may quote provider text (the JSON parser's message), so the class
    # deliberately does NOT include `Tamoz::DisclosableMessage`.
    class ProtocolError < Tamoz::Error
    end
  end
end
