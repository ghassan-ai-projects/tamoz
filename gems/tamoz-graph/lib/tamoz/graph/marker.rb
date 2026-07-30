# frozen_string_literal: true

module Tamoz
  module Graph
    Marker = Data.define(:name) do
      def initialize(name)
        super(name: String(name).dup.freeze)
      end

      def inspect
        "Tamoz::#{name}"
      end

      alias to_s inspect
    end

    private_constant :Marker
  end

  marker_class = Graph.const_get(:Marker, false)
  START = marker_class.new("START")
  const_set(:END, marker_class.new("END"))
end
