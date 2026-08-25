# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # The profile's egress declaration (P17 §4), validated field by field.
      #
      # Split out of the loader as one cohesive check with its own vocabulary:
      # allowlisted hosts, schemes, byte and timeout limits, the breaker, and
      # credential REFERENCES. It is fail-closed by construction — every field is
      # required and bounded, so a declaration can only narrow what the adapter
      # will do, never widen it. The per-hop adapter check is the second layer;
      # this one never sees a credential value, only a name.
      #
      # Holds (egress, path) as state so each step reads as the question it asks
      # rather than threading the same two arguments through a dozen predicates.
      #
      # :reek:DataClump — (host, field) is a value and the label the error message
      # calls it by. They travel together because every refusal has to name what
      # it refused; deriving the label again in each check would duplicate the
      # message-formatting rule instead of removing the pair.
      # :reek:TooManyMethods — the method list IS the field list of the egress
      # schema; collapsing it would only re-inline the checks it names.
      # :reek:MissingSafeMethod — every step is a raise-on-invalid guard. The bang
      # is the contract; a predicate twin would invite checking without enforcing,
      # which is the failure mode this validator exists to prevent.
      # :reek:TooManyStatements — `validate!` is the ordered list of checks and
      # `validate_circuit!` is one nested mapping's fields; the order is the
      # behaviour (it fixes which error a bad profile reports first), so neither
      # list can be shortened without changing what the loader says.
      class EgressValidator
        HOST_DELIMITERS = ['/', '@', ':'].freeze
        # Returns the validated egress mapping, or nil when the profile declares
        # none — absence means "no egress", which is the closed default.
        #
        # :reek:NilCheck — absence IS the domain value here; `nil` distinguishes
        # "declared nothing" from "declared an empty egress".
        def self.call(hash, path)
          egress = hash['egress']
          return nil if egress.nil?

          new(egress, path).validate!
        end

        def initialize(egress, path)
          @egress = egress
          @path = path
        end

        def validate!
          validate_shape!
          validate_hosts!
          validate_schemes!
          validate_limits!
          validate_circuit!
          validate_credential_refs!
          @egress
        end

        private

        def validate_shape!
          raise ValidationError, "#{@path}: egress must be a mapping" unless @egress.is_a?(Hash)

          unknown = @egress.keys - EGRESS_KEYS
          return if unknown.empty?

          raise ValidationError, "#{@path}: unknown egress fields #{unknown.sort.inspect}"
        end

        # :reek:FeatureEnvy — the array under test is a local read out of @egress.
        def validate_hosts!
          hosts = @egress['allowlisted_hosts']
          unless hosts.is_a?(Array) && !hosts.empty? &&
                 hosts.all?(String) && hosts.uniq == hosts
            raise ValidationError,
                  "#{@path}: egress.allowlisted_hosts must be a non-empty array of distinct strings"
          end

          hosts.each { |host| validate_host!(host) }
        end

        # A host that looks like a credential name is refused outright: names
        # belong in credential_refs, and a value must never reach a profile at all.
        def validate_host!(host)
          field = "egress.allowlisted_hosts entry #{host.inspect}"
          if EGRESS_CREDENTIAL_NAME_PATTERN.match?(host)
            raise ValidationError,
                  "#{@path}: #{field} is credential-shaped; names belong in " \
                  'egress.credential_refs only (values never enter a profile)'
          end

          validate_dns_name!(host, field)
        end

        # Exact absolute DNS FQDN: lowercase, at least two dot-separated labels,
        # no wildcard, no IP literal in any spelling, no scheme/port/path/
        # userinfo. v1 deliberately has no wildcards or IP-literal allowlisting;
        # the per-hop adapter check is the second layer (P17 §4).
        #
        def validate_dns_name!(host, field)
          validate_dns_spelling!(host, field)
          refuse_ip_literal!(host, field)
          validate_dns_labels!(host, field)
          host
        end

        # Refusals about how the name is written, in the order a reader would
        # check them. The order is behaviour: it fixes which complaint a badly
        # spelled host gets first.
        #
        # :reek:TooManyStatements — four independent refusals, each with its own
        # message; the list is the smallest unit.
        def validate_dns_spelling!(host, field)
          if host.bytesize > 253 || host.empty?
            raise ValidationError, "#{@path}: #{field} must be an absolute DNS name of at most 253 bytes"
          end
          if host.include?('*')
            raise ValidationError, "#{@path}: #{field} contains a wildcard; v1 allows exact FQDNs only"
          end
          if delimited?(host)
            raise ValidationError,
                  "#{@path}: #{field} must be a bare hostname with no scheme, port, path, or userinfo"
          end

          raise ValidationError, "#{@path}: #{field} must be lowercase" unless host == host.downcase
        end

        # A scheme, port, path, userinfo or any whitespace makes this not a bare
        # hostname.
        #
        # :reek:UtilityFunction — a pure spelling predicate over one string.
        def delimited?(host)
          HOST_DELIMITERS.any? { |delimiter| host.include?(delimiter) } || host.match?(/\s/)
        end

        # Every spelling of an IP literal, including the decimal/hex/octal forms
        # that would otherwise slip past a dotted-quad check.
        def refuse_ip_literal!(host, field)
          return unless EGRESS_IPV4_PATTERN.match?(host) || EGRESS_IPV6_PATTERN.match?(host) ||
                        EGRESS_NUMERIC_IP_PATTERN.match?(host)

          raise ValidationError, "#{@path}: #{field} is an IP literal; v1 allows exact FQDNs only"
        end

        def validate_dns_labels!(host, field)
          labels = host.split('.')
          unless labels.length >= 2 && labels.none?(&:empty?) &&
                 labels.all? { |label| label.bytesize <= 63 && EGRESS_HOST_LABEL_PATTERN.match?(label) }
            raise ValidationError, "#{@path}: #{field} is not a valid absolute DNS name"
          end
          return unless labels.last.match?(/\A\d+\z/)

          raise ValidationError, "#{@path}: #{field} must not end in a numeric label"
        end

        def validate_schemes!
          schemes = @egress['schemes']
          return if schemes == EGRESS_SCHEMES

          raise ValidationError, "#{@path}: egress.schemes must be exactly #{EGRESS_SCHEMES.inspect} in v1"
        end

        def validate_limits!
          validate_boolean!(@egress['deny_private_ranges'], 'egress.deny_private_ranges')
          validate_integer!(@egress['max_request_bytes'], 'egress.max_request_bytes', 1..EGRESS_MAX_REQUEST_BYTES)
          validate_integer!(@egress['max_response_bytes'], 'egress.max_response_bytes', 1..EGRESS_MAX_RESPONSE_BYTES)
          validate_timeout!
          validate_integer!(@egress['redirect_max_hops'], 'egress.redirect_max_hops', 1..EGRESS_MAX_REDIRECT_HOPS)
        end

        # :reek:FeatureEnvy — four questions about one local read out of @egress.
        def validate_timeout!
          timeout = @egress['connect_timeout_s']
          return if timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? &&
                    timeout <= EGRESS_MAX_CONNECT_TIMEOUT_S

          raise ValidationError,
                "#{@path}: egress.connect_timeout_s must be a positive finite number " \
                "of at most #{EGRESS_MAX_CONNECT_TIMEOUT_S}"
        end

        def validate_circuit!
          circuit = @egress['circuit']
          raise ValidationError, "#{@path}: egress.circuit must be a mapping" unless circuit.is_a?(Hash)

          unknown = circuit.keys - EGRESS_CIRCUIT_KEYS
          raise ValidationError, "#{@path}: unknown egress.circuit fields #{unknown.sort.inspect}" unless unknown.empty?
          unless circuit['scope_type'] == EGRESS_SCOPE_TYPE
            raise ValidationError, "#{@path}: egress.circuit.scope_type must be #{EGRESS_SCOPE_TYPE.inspect}"
          end

          validate_integer!(circuit['threshold'], 'egress.circuit.threshold', 1..EGRESS_MAX_CIRCUIT_THRESHOLD)
          validate_boolean!(circuit['budget_breach'], 'egress.circuit.budget_breach')
        end

        # Names only. The pattern is the same one a model role's credential_ref
        # passes, so there is one spelling of "this is a reference, not a secret".
        def validate_credential_refs!
          refs = @egress['credential_refs']
          return if refs.is_a?(Array) && refs.uniq == refs &&
                    refs.all? { |name| name.is_a?(String) && CREDENTIAL_REF_PATTERN.match?(name) }

          raise ValidationError,
                "#{@path}: egress.credential_refs must be distinct names matching " \
                "#{CREDENTIAL_REF_PATTERN.inspect}; names only, values never enter a profile"
        end

        def validate_boolean!(value, field)
          return if [true, false].include?(value)

          raise ValidationError, "#{@path}: #{field} must be true or false"
        end

        # The bounds travel as a Range so the two of them cannot be passed in the
        # wrong order; the message still names them separately.
        #
        # :reek:FeatureEnvy — the Range is the thing being asked about.
        def validate_integer!(value, field, bounds)
          return value if value.is_a?(Integer) && bounds.cover?(value)

          raise ValidationError,
                "#{@path}: #{field} must be an integer between #{bounds.min} and #{bounds.max}"
        end
      end
    end
  end
end
