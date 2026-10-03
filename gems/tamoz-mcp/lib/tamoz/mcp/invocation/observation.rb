# frozen_string_literal: true

module Tamoz
  module Mcp
    module Invocation
      Observation = Data.define(
        :server_id, :content_blocks, :text, :structured_content, :truncated
      ) do
        def attributed?
          content_blocks.all? do |block|
            block['attribution'] == format(ATTRIBUTION_TEMPLATE, server_id)
          end
        end

        def to_h
          {
            'server_id' => server_id,
            'content_blocks' => content_blocks,
            'text' => text,
            'structured_content' => structured_content,
            'truncated' => truncated
          }.freeze
        end
      end
    end
  end
end
