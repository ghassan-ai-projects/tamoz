# frozen_string_literal: true

module Tamoz
  module Mcp
    # Validates server identity, protocol range and configured primitive budgets.
    class ServerAdmission
      def validate_identity!(server_id, transport)
        [validate_server_id!(server_id), validate_transport!(transport)]
      end

      def validate_server_id!(value)
        unless value.is_a?(String) && SERVER_ID_PATTERN.match?(value)
          raise ValidationError,
                "server_id must match #{SERVER_ID_PATTERN.inspect}, got #{value.inspect}"
        end

        value.dup.freeze
      end

      def validate_transport!(value)
        unless %i[stdio http].include?(value)
          raise ValidationError, "transport must be :stdio or :http, got #{value.inspect}"
        end

        value
      end

      def validate_credential_refs!(value)
        raise ValidationError, 'credential_refs must be an array of explicit names' unless value.is_a?(Array)

        value.map do |name|
          unless name.is_a?(String) && CREDENTIAL_REF_PATTERN.match?(name)
            raise ValidationError,
                  "credential_refs entries must match #{CREDENTIAL_REF_PATTERN.inspect}, " \
                  "got #{name.inspect}"
          end

          name.dup.freeze
        end.freeze
      end

      def validate_protocol_range!(value)
        unless value.is_a?(Array) && value.length == 2 &&
               value.all? { |v| v.is_a?(String) && PROTOCOL_VERSION_PATTERN.match?(v) }
          raise ValidationError,
                'protocol_range must be [min, max] of YYYY-MM-DD protocol versions'
        end
        min, max = value
        raise ValidationError, "protocol_range min #{min.inspect} is after max #{max.inspect}" if min > max

        value.map { |v| v.dup.freeze }.freeze
      end

      def validate_primitives!(value)
        unless value.is_a?(Array) && !value.empty? &&
               value.all? { |p| p.is_a?(Symbol) && PRIMITIVES.include?(p) }
          raise ValidationError,
                "primitives must be a non-empty subset of #{PRIMITIVES.inspect}"
        end

        value.uniq.freeze
      end

      def validate_budgets!(value)
        raise ValidationError, 'budgets must be a Tamoz::Mcp::ServerConfig::Budgets' unless value.is_a?(Budgets)

        value
      end
    end
    private_constant :ServerAdmission
  end
end
