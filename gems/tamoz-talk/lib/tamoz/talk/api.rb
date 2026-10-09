# frozen_string_literal: true

require 'json'

module Tamoz
  module Talk
    # The /v1 routes, after the token was checked: each returns [status, body, content type].
    class Api
      JSON_TYPE = 'application/json'
      SUBMITTED = { admitted: 200, timeout: 503, stopping: 503, full: 429 }.freeze
      REFERENCE = /\A\h{32}\z/

      def initialize(hub, trace: false)
        @hub = hub
        @trace = trace
      end

      def call(request, body, limits)
        route = [request.method, request.path]
        case route
        in ['POST', '/v1/messages'] then message(read_json(body, limits, request))
        in ['POST', '/v1/utterances'] then utterance(request, body.call(limits.fetch(request.path)))
        in ['POST', '/v1/decisions'] then decision(read_json(body, limits, request))
        in ['GET', '/v1/events'] then events(request.query)
        in ['GET', %r{\A/v1/speech/(\d{1,16})\z}] then speech(Integer(request.path.split('/').last, 10))
        in ['GET', '/v1/trace'] if @trace then json(200, @hub.trace)
        in [_, '/v1/messages' | '/v1/utterances' | '/v1/decisions' | '/v1/events'] then json(405, error: 'method')
        else json(404, error: 'not found')
        end
      rescue JSON::ParserError, Comms::ValidationError, KeyError, TypeError, ArgumentError
        json(400, error: 'malformed request')
      end

      private

      def message(fields)
        text = fields.fetch('text')
        raise ArgumentError unless text.is_a?(String) && text.valid_encoding? && !text.strip.empty?

        submitted(@hub.normalizer.text(update_id: fields.fetch('update_id'), text:))
      end

      def utterance(request, audio)
        return json(415, error: 'audio/wav only') unless request.header('content-type').to_s.start_with?('audio/wav')

        update_id = Integer(request.query.fetch('update_id'), 10)
        duration = Wav.duration(audio)
        return json(413, error: 'longer than 60 s') if duration > Wav::MAX_SECONDS

        submitted(@hub.normalizer.utterance(update_id:, audio:, duration_s: duration), audio:)
      rescue Wav::Error
        json(415, error: 'not a 16 kHz 16-bit mono WAV')
      end

      def decision(fields)
        action = fields.fetch('action')
        reference = fields.fetch('reference')
        raise ArgumentError unless %w[approve deny].include?(action) && reference.is_a?(String) &&
                                   reference.match?(REFERENCE)

        submitted(@hub.normalizer.decision(update_id: fields.fetch('update_id'), action:, reference:,
                                           message_id: Integer(fields.fetch('message_id'))))
      end

      def events(query)
        timeout = [Integer(query.fetch('timeout', '25'), 10), Server::MAX_EVENTS_WAIT_S].min
        json(200, @hub.log.since(after: Integer(query.fetch('after', '0'), 10), epoch: query['epoch'],
                                 timeout_s: [timeout, 0].max, speech: query['speech'] == '1'))
      end

      def speech(message_id)
        audio = @hub.speaker.speech(message_id)
        return json(404, error: 'not a spoken message') if audio == :not_spoken
        return json(502, error: 'speech unavailable') if audio == :failed

        [200, audio, 'audio/mpeg']
      end

      def submitted(envelope, audio: nil)
        outcome = @hub.inbox.submit(envelope, audio:, timeout_s: @hub.submit_timeout_s)
        json(SUBMITTED.fetch(outcome), outcome == :admitted ? { admitted: true } : { error: outcome })
      end

      def read_json(body, limits, request)
        parsed = JSON.parse(body.call(limits.fetch(request.path)))
        raise ArgumentError unless parsed.is_a?(Hash)

        parsed
      end

      def json(status, document) = [status, JSON.generate(document), JSON_TYPE]
    end
  end
end
