# frozen_string_literal: true

module Tamoz
  Send = Data.define(:node, :input, :key) do
    def initialize(node:, input:, key: nil)
      normalized_node = Graph.const_get(:Identifier, false).symbol(node, name: "send node")
      normalized_input = StateCodec.new.normalize(input)
      raise InvalidUpdateError, "Send input must be a Hash" unless normalized_input.is_a?(Hash)
      normalized_key = if key.nil?
                         nil
                       else
                         Graph.const_get(:Identifier, false).version(key, name: "send key")
                       end
      super(node: normalized_node, input: normalized_input, key: normalized_key)
    end
  end

  def self.send_to(node, input, key: nil)
    Send.new(node:, input:, key:)
  end
end
