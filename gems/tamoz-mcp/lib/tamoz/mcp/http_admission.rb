# frozen_string_literal: true

module Tamoz
  module Mcp
    # Admits MCP endpoint egress and credential-safe HTTP headers.
    class HttpAdmission
      def validate_allow_insecure_http!(value)
        return value if [true, false].include?(value)

        raise ValidationError, 'allow_insecure_http must be a boolean'
      end

      def validate_endpoint!(value, transport, allow_insecure_http)
        return nil if transport == :stdio && value.nil?

        uri = parse_endpoint_uri!(value, transport)
        validate_endpoint_security!(uri, allow_insecure_http)
        value.dup.freeze
      end

      def parse_endpoint_uri!(value, transport)
        unless transport == :http && value.is_a?(String) && !value.empty?
          raise ValidationError, 'endpoint is required for :http and must be an absolute URL'
        end

        uri = URI.parse(value)
        validate_endpoint_uri!(uri)

        uri
      rescue URI::InvalidURIError
        raise ValidationError, 'endpoint must be an absolute http(s) URL'
      end

      def validate_endpoint_uri!(uri)
        return if %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil? && uri.fragment.nil?

        raise ValidationError, 'endpoint must be an absolute http(s) URL without userinfo or fragments'
      end

      def validate_endpoint_security!(uri, allow_insecure_http)
        return unless uri.scheme == 'http'
        return if loopback_host?(uri.host)
        return if allow_insecure_http && private_ip_host?(uri.host)

        raise ValidationError, 'endpoint must use https unless it targets loopback'
      end

      def loopback_host?(host)
        %w[localhost 127.0.0.1 ::1].include?(host.downcase.delete('[]'))
      end

      def private_ip_host?(host)
        IPAddr.new(host.delete('[]')).private?
      rescue IPAddr::InvalidAddressError
        false
      end

      def validate_headers!(value)
        raise ValidationError, 'headers must be a mapping of non-secret names to strings' unless value.is_a?(Hash)

        value.each_with_object({}) do |(name, header_value), result|
          validate_header_name!(name)
          if credential_header_name?(name)
            raise ValidationError, "headers cannot contain credential-bearing #{name.inspect}; use credential_headers"
          end

          validate_header_value!(header_value)
          result[name.dup.freeze] = header_value.dup.freeze
        end.freeze
      end

      def validate_credential_headers!(value, credential_refs, static_headers)
        unless value.is_a?(Hash)
          raise ValidationError, 'credential_headers must map HTTP header names to credential refs'
        end

        static_names = static_headers.keys.map(&:downcase)
        value.each_with_object({}) do |(name, ref), result|
          validate_header_name!(name)
          if static_names.include?(name.downcase)
            raise ValidationError, "credential_headers cannot duplicate static header #{name.inspect}"
          end
          unless ref.is_a?(String) && credential_refs.include?(ref)
            raise ValidationError,
                  "credential_headers entry #{name.inspect} must reference a name in credential_refs"
          end

          result[name.dup.freeze] = ref.dup.freeze
        end.freeze
      end

      def validate_header_name!(name)
        return if name.is_a?(String) && name.match?(/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/)

        raise ValidationError, 'HTTP header names must be valid strings'
      end

      def validate_header_value!(value)
        return if value.is_a?(String) && value.bytesize <= 4096 && !CONTROL_CHARACTER_PATTERN.match?(value)

        raise ValidationError, 'HTTP header values must be bounded strings without control characters'
      end

      def credential_header_name?(name)
        name.match?(/authorization|cookie|token|secret|api[-_]?key|password/i)
      end
    end
    private_constant :HttpAdmission
  end
end
