# frozen_string_literal: true

require 'ipaddr'
require 'socket'
require 'uri'

module Tamoz
  module OTel
    class EgressPolicy
      MAX_TIMEOUT_MS = 30_000

      attr_reader :endpoint, :allow_local, :timeout_ms, :max_batch, :credential_ref

      def initialize(endpoint:, allow_local: false, timeout_ms: 2_000, max_batch: 256, credential_ref: nil)
        @endpoint = URI.parse(String(endpoint))
        @allow_local = !!allow_local
        @timeout_ms = bounded_integer(timeout_ms, :timeout_ms, MAX_TIMEOUT_MS)
        @max_batch = bounded_integer(max_batch, :max_batch, 10_000)
        @credential_ref = normalize_credential_ref(credential_ref)
        validate_endpoint!
        freeze
      rescue URI::InvalidURIError => error
        raise Tamoz::Observability::ValidationError, "invalid OTLP endpoint: #{error.message}"
      end

      def uri
        endpoint.dup.freeze
      end

      def resolved_addresses
        Socket.getaddrinfo(endpoint.hostname, endpoint.port, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
              .map { |entry| entry.fetch(3) }.uniq
      end

      def validate_resolved_addresses!(addresses)
        return if allow_local
        return unless addresses.any? { |address| private_ip?(address) }

        raise Tamoz::Observability::ValidationError,
              'private and loopback OTLP destinations require allow_local'
      end

      private

      def bounded_integer(value, name, maximum)
        return value if value.is_a?(Integer) && value.positive? && value <= maximum

        raise Tamoz::Observability::ValidationError, "#{name} must be between 1 and #{maximum}"
      end

      def normalize_credential_ref(value)
        return nil if value.nil?
        raise Tamoz::Observability::ValidationError, 'credential_ref must be a Hash' unless value.is_a?(Hash)

        kind = value[:kind] || value['kind']
        name = value[:name] || value['name']
        unless kind.to_s == 'env' && name.to_s.match?(/\A[A-Z][A-Z0-9_]{0,127}\z/)
          raise Tamoz::Observability::ValidationError, 'credential_ref must name an environment variable'
        end

        {'kind' => 'env', 'name' => name.to_s}.freeze
      end

      def validate_endpoint!
        raise Tamoz::Observability::ValidationError, 'OTLP endpoint must use https' unless endpoint.scheme == 'https'
        raise Tamoz::Observability::ValidationError, 'OTLP endpoint must include a host' if endpoint.host.to_s.empty?
        raise Tamoz::Observability::ValidationError, 'OTLP endpoint cannot include credentials' if endpoint.userinfo
        raise Tamoz::Observability::ValidationError, 'OTLP endpoint cannot include query or fragment' if endpoint.query || endpoint.fragment
        return if allow_local

        host = endpoint.hostname
        if %w[localhost localhost.localdomain].include?(host.downcase) || private_ip?(host)
          raise Tamoz::Observability::ValidationError, 'private and loopback OTLP endpoints require allow_local'
        end
      end

      def private_ip?(host)
        address = IPAddr.new(host)
        address.private? || address.loopback? || address.link_local?
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
