# frozen_string_literal: true

require 'digest'

module Tamoz
  module Comms
    # Deterministic chat rendering (design §11): one message per lifecycle
    # event, never per token; parts split at paragraph, then line, then a hard
    # grapheme boundary; the same input produces byte-identical parts for the
    # same render version; overflow beyond max_parts truncates explicitly.
    # The splitter is one deterministic pipeline; the metric smells measure
    # the rendering contract, not a choice to overload.
    # :reek:DuplicateMethodCall, :reek:TooManyStatements, :reek:ManualDispatch
    module Rendering
      RENDER_VERSION = 1
      TEXT_DOMAIN = 'tamoz.comms.render.text.v1'

      # @return [Array<Hash>] `{text:, content_digest:, part_index:, part_count:}`
      # :reek:LongParameterList -- the rendering contract binds the ceiling,
      #   part budget and overflow policy in one call.
      def self.plain(text, max_parts:, part_characters:, overflow: 'truncate')
        parts = split(text, part_characters:, max_parts:, overflow:)
        count = parts.length
        parts.each_with_index.map do |part, index|
          {
            'text' => part,
            'content_digest' => content_digest(part),
            'part_index' => index,
            'part_count' => count
          }
        end
      end

      # @return [String] the digest over the exact outbound bytes.
      def self.content_digest(part)
        ::Digest::SHA256.hexdigest("#{TEXT_DOMAIN}\n#{part}")
      end

      # :reek:LongParameterList, :reek:ControlParameter -- the split policy
      #   (overflow branch) is the contract.
      def self.split(text, part_characters:, max_parts:, overflow:)
        ceiling = [part_characters, 4096].min
        text = text[0, ceiling * max_parts] if overflow == 'truncate'
        chunks = grapheme_chunks(text)
        parts = []
        until chunks.empty? || parts.length >= max_parts
          part, chunks = take_part(chunks, ceiling:)
          parts << part
        end
        parts << chunks.join if parts.length < max_parts && !chunks.empty?
        parts
      end

      def self.take_part(chunks, ceiling:)
        # Consumes whole grapheme clusters; falls back to a hard boundary only
        # when a single cluster exceeds the ceiling (a pathological link).
        part = +''
        while (chunk = chunks.first) && (part.length + chunk.length) <= ceiling
          part << chunks.shift
        end
        part << chunks.shift if part.empty? && chunks.first
        [part, chunks]
      end

      # Splits into grapheme clusters via the unicode extension; falls back to
      # codepoints when unavailable.
      def self.grapheme_chunks(text)
        if text.respond_to?(:each_grapheme_cluster)
          text.each_grapheme_cluster.to_a
        else
          text.each_char.to_a
        end
      end
      private_class_method :split, :take_part, :grapheme_chunks
    end
  end
end
