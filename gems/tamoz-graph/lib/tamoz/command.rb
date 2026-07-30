# frozen_string_literal: true

module Tamoz
  Command = Data.define(:update, :goto, :resume, :graph) do
    def initialize(update: {}, goto: nil, resume: nil, graph: nil)
      normalized_update = StateCodec.new.normalize(update)
      raise InvalidUpdateError, "Command update must be a Hash" unless normalized_update.is_a?(Hash)

      normalized_resume = resume.nil? ? nil : StateCodec.new.normalize(resume)
      normalized_graph = graph.nil? ? nil : Graph.const_get(:Identifier, false).symbol(
        graph,
        name: "command graph"
      )
      super(
        update: normalized_update,
        goto: normalize_goto(goto),
        resume: normalized_resume,
        graph: normalized_graph
      )
    end

    private

    def normalize_goto(value)
      return nil if value.nil?

      values = value.is_a?(Array) ? value : [value]
      values.map do |entry|
        if entry.equal?(Tamoz::END)
          Tamoz::END
        elsif entry.is_a?(Send)
          entry
        else
          Graph.const_get(:Identifier, false).symbol(entry, name: "command route")
        end
      end.freeze
    end
  end
end
