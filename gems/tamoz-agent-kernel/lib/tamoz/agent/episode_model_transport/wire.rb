# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    class EpisodeModelTransport
      # The transport's byte work with no I/O: reading provider envelopes and building the upload body.
      module Wire
        module_function

        def sha256(bytes) = "sha256:#{Digest::SHA256.hexdigest(bytes)}"

        def tool_calls_from(calls)
          Array(calls).map do |call|
            function = call.fetch('function')
            arguments = function.fetch('arguments')
            raise ProtocolError, 'tool call arguments must be a JSON string' unless arguments.is_a?(String)

            { 'id' => String(call.fetch('id')), 'name' => String(function.fetch('name')), 'arguments' => arguments }
          end
        end

        # The provider's own usage counts, integers only; the context engine interprets them.
        def provider_usage(raw)
          return nil unless raw.is_a?(Hash)

          counts = raw.select { |_, value| value.is_a?(Integer) && value >= 0 }
          details = raw['prompt_tokens_details']
          cached = details.is_a?(Hash) && details['cached_tokens']
          counts = counts.merge('prompt_tokens_details' => { 'cached_tokens' => cached }) if cached.is_a?(Integer)
          counts.empty? ? nil : counts
        end

        def extract_content(bytes)
          parsed = Tamoz::Core.parse_json_strict(bytes)
          raise ProtocolError, 'episode model response is not an object' unless parsed.is_a?(Hash)

          content = parsed.dig('choices', 0, 'message', 'content')
          if content.nil? || !content.is_a?(String)
            raise ProtocolError, 'episode model response has no assistant content'
          end

          content
        end

        def extract_usage_hash(bytes)
          parsed = Tamoz::Core.parse_json_strict(bytes)
          parsed.is_a?(Hash) ? parsed.fetch('usage', {}) : {}
        end

        def usage_from(raw)
          return ModelCall::Usage.unavailable unless raw.is_a?(Hash)

          input = integer_field(raw, 'prompt_tokens')
          output = integer_field(raw, 'completion_tokens')
          return ModelCall::Usage.unavailable if input.nil? || output.nil?

          ModelCall::Usage.of(input_tokens: input.to_i, output_tokens: output.to_i, cost_microunits: 0)
        end

        def integer_field(raw, key)
          value = raw[key]
          value.is_a?(Integer) && value >= 0 ? value : nil
        end

        def mp3?(audio)
          return true if audio.start_with?('ID3'.b)

          audio.bytesize > 1 && audio.getbyte(0) == 0xFF && audio.getbyte(1).allbits?(0xE0)
        end

        def transcription_body(model, audio, filename, media_type, boundary)
          name = filename.to_s.gsub(/[^A-Za-z0-9._-]/, '_')
          media_type = 'application/octet-stream' unless media_type.to_s.match?(%r{\A[\w.+-]+/[\w.+-]+\z})
          head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n#{model}\r\n" \
                 "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{name}\"\r\n" \
                 "Content-Type: #{media_type}\r\n\r\n"
          head.b + audio.b + "\r\n--#{boundary}--\r\n".b
        end
      end
    end
  end
end
