# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # One ordered block of system prompt text.
    Section = Data.define(:name, :order, :text) do
      def initialize(name:, order:, text:)
        raise Error, 'section name must be a non-empty String' unless name.is_a?(String) && !name.empty?
        raise Error, "section #{name} order must be an Integer" unless order.is_a?(Integer)
        raise Error, "section #{name} text must be a String" unless text.is_a?(String)

        super(name: name.dup.freeze, order:, text: text.strip.freeze)
      end

      def sort_key = [order, name.b]
    end
  end
end
