# frozen_string_literal: true

module Tamoz
  module Talk
    # The talk kind's runtime half: one hub per surface, its page served only while the gateway holds the lease.
    class Channel
      include Comms::Channel

      TRACE = 'TAMOZ_TALK_TRACE'
      LOOPBACK = %w[127.0.0.1 localhost ::1].freeze
      DEFAULT_HOST = '127.0.0.1'
      SETTINGS = %i[port allow_hosts host].freeze
      MAX_ALLOW_HOSTS = 16
      HOST_NAME = /\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/i

      # The hub's page and inbox, started after the lease and stopped with the gateway.
      class Connection
        include Comms::Channel::Connection

        attr_reader :transport

        def initialize(hub)
          @hub = hub
          @transport = hub.transport
        end

        def start(floor:, history:)
          @hub.resume(floor: floor.to_i, history:)
          @hub.start
        rescue Errno::EADDRINUSE, Errno::EACCES, Errno::EADDRNOTAVAIL => e
          raise Comms::ConnectionError, "the talk page could not listen (#{e.class.name.split('::').last}); is " \
                                        'another Tamoz running, or is the port taken?'
        end

        def stop = @hub.stop
        def interval_s = 0.1
      end

      def self.host(settings) = settings.fetch(:host, DEFAULT_HOST)

      def validate!(descriptor)
        settings = descriptor.settings
        unless descriptor.transport.dig(:credential_ref, :name) == Setup::TOKEN
          raise Comms::ValidationError, "a talk surface's credential is #{Setup::TOKEN}"
        end

        unknown = settings.keys - SETTINGS
        raise Comms::ValidationError, "a talk surface has no setting #{unknown.first}" unless unknown.empty?

        port = settings[:port]
        unless port.is_a?(Integer) && (1..65_535).cover?(port)
          raise Comms::ValidationError,
                'a talk surface needs a port'
        end

        validate_hosts!(settings.fetch(:allow_hosts, []), self.class.host(settings))
      end

      def connect(descriptor, env:, voice: nil)
        token = env.fetch(descriptor.transport.fetch(:credential_ref).fetch(:name))
        Connection.new(Hub.new(descriptor:, token:, synthesize: voice, host: self.class.host(descriptor.settings),
                               trace: env[TRACE] == '1'))
      end

      private

      def validate_hosts!(hosts, host)
        validate_allow_hosts!(hosts)
        raise Comms::ValidationError, 'the talk host must be a string' unless host.is_a?(String)
        return if LOOPBACK.include?(host) || !hosts.empty?

        raise Comms::ValidationError, "listening on #{host} needs `tamoz channel add talk --allow-host NAME` for the " \
                                      'name the page is reached by'
      end

      def validate_allow_hosts!(hosts)
        valid = hosts.is_a?(Array) && hosts.length <= MAX_ALLOW_HOSTS && hosts.uniq.length == hosts.length &&
                hosts.all? { |name| name.is_a?(String) && name.match?(HOST_NAME) }
        raise Comms::ValidationError, "allow_hosts must be at most #{MAX_ALLOW_HOSTS} host names" unless valid
      end
    end
  end
end
