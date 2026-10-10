# frozen_string_literal: true

module Tamoz
  module Telegram
    # The Telegram kind's runtime half: one Bot API transport, shared by the gateway's poller and its drainer.
    class Channel
      include Comms::Channel

      ORIGIN = 'TAMOZ_TELEGRAM_API_ORIGIN'
      SETTINGS = %i[bot_username].freeze

      def self.stream(bot_id) = "telegram:bot:#{bot_id}"

      # Nothing to open or close: the Bot API is reached per call.
      class Connection
        include Comms::Channel::Connection

        attr_reader :transport

        def initialize(transport) = @transport = transport
        def interval_s = 1.0
      end

      def initialize(client_factory: nil)
        @client_factory = client_factory
      end

      def validate!(descriptor)
        raise Comms::ValidationError, 'a Telegram surface cannot speak its replies' if descriptor.speech?
        unless descriptor.transport.dig(:credential_ref, :name) == Setup::TOKEN
          raise Comms::ValidationError, "a Telegram surface's credential is #{Setup::TOKEN}"
        end

        unknown = descriptor.settings.keys - SETTINGS
        raise Comms::ValidationError, "a Telegram surface has no setting #{unknown.first}" unless unknown.empty?
        return if descriptor.settings.fetch(:bot_username, '').is_a?(String)

        raise Comms::ValidationError, 'bot_username must be a string'
      end

      def connect(descriptor, env:, voice: nil) # rubocop:disable Lint/UnusedMethodArgument
        token = env.fetch(descriptor.transport.fetch(:credential_ref).fetch(:name))
        normalizer = Normalizer.new(surface_id: descriptor.surface_id, surface_revision: descriptor.revision,
                                    bot_username: descriptor.settings[:bot_username])
        Connection.new(Transport.new(client: client(token, env, descriptor.transport[:max_response_bytes]),
                                     normalizer:))
      end

      def client(token, env, max_response_bytes = nil)
        return @client_factory.call(token) if @client_factory

        origin = env[ORIGIN].to_s
        Client.new(token, max_response_bytes:, origin: origin.empty? ? Client::DEFAULT_ORIGIN : origin)
      end
    end
  end
end
