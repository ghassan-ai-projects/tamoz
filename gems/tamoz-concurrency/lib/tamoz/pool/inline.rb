# frozen_string_literal: true

module Tamoz
  module Pool
    # Runs every task on the calling thread, in order.
    class Inline < Base
      def map(items, cancellation: nil, &block)
        raise ArgumentError, 'a pool block is required' unless block

        token = cancellation_for(cancellation)
        bounded_items(items).each_with_index.map do |item, index|
          execute(index, item, token, block)
        end.freeze
      end
    end

    private_constant :Inline
  end
end
