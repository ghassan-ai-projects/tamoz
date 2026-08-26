# frozen_string_literal: true

require "ipaddr"
require "uri"

module Tamoz
  module Mcp
    module Websearch
      # The operator-declared egress policy for one governed websearch server
      # (P17 §3). Tamoz's own copy of the declaration lives in the P8 profile
      # (`egress:` section, validated by `Tamoz::Agent::Profile`); this is the
      # `tamoz-mcp`-side copy the operator-side server process runs under —
      # deliberate duplication only across the gem boundary, per the P8-E
      # precedent (tamoz-mcp must not depend on tamoz-agent).
      #
      # Enforcement point (honest claim, correction 2): TAMOZ ITSELF NEVER MAKES
      # AN OUTBOUND CALL. The network-capable process is operator-supplied and
      # its egress is enforced OUTSIDE Tamoz — this policy object is what that
      # operator-side process applies per-hop, and Tamoz's own copy is what it
      # pins and validates. Any "runtime comparison" a caller surfaces is a
      # SELF-REPORTED, `author_claimed` check with no enforcement value
      # (invariant 35: a self-report is not policy).
      class EgressPolicy
        SCHEMES = ["https"].freeze
        SCOPE_TYPE = "egress"
        MAX_REQUEST_BYTES = 8192
        MAX_RESPONSE_BYTES = 64 * 1024
        MAX_CONNECT_TIMEOUT_S = 300
        MAX_REDIRECT_HOPS = 10
        MIN_REDIRECT_HOPS = 1
        MAX_CIRCUIT_THRESHOLD = 10
        CREDENTIAL_REF_PATTERN = /\ATAMOZ_[A-Z0-9_]+\z/
        HOST_LABEL_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
        IPV4_PATTERN = /\A(?:\d{1,3}\.){3}\d{1,3}\z/
        # IPv6 in any standard spelling (compressed, IPv4-mapped, zone-id).
        IPV6_PATTERN = /\A[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%[0-9A-Za-z.]+)?\z/
        # Bare decimal / hex / octal spellings of an IPv4 address.
        NUMERIC_IP_PATTERN = /\A(?:\d+|0[xX][0-9A-Fa-f]+|0[0-7]+)\z/
        CREDENTIAL_NAME_PATTERN = /(?:\A|_)(?:
          API_?KEYS? | ACCESS_?KEYS? | SECRET_?KEYS? | PRIVATE_?KEYS? | SESSION_?KEYS? |
          TOKENS? | SECRETS? | PASSWORD | PASSWD | CREDENTIALS? | PASSPHRASE
        )(?:\z|_)/x

        ValidationError = Class.new(Tamoz::Mcp::ValidationError)

        attr_reader :allowlisted_hosts, :schemes, :deny_private_ranges,
                    :max_request_bytes, :max_response_bytes, :connect_timeout_s,
                    :redirect_max_hops, :circuit, :credential_refs

        # Fail-closed construction from the operator-supplied declaration (the
        # same shape Tamoz validates in the profile). Raises the typed
        # `ValidationError` naming the offending field; a malformed declaration
        # never reaches the dial path.
        def initialize(declaration)
          validate_declaration_shape!(declaration)

          @allowlisted_hosts = validate_hosts!(declaration["allowlisted_hosts"])
          @schemes = validate_schemes!(declaration["schemes"])
          @deny_private_ranges = validate_deny_private_ranges!(declaration["deny_private_ranges"])
          @max_request_bytes = bounded_integer!(declaration["max_request_bytes"], "max_request_bytes", 1, MAX_REQUEST_BYTES)
          @max_response_bytes = bounded_integer!(declaration["max_response_bytes"], "max_response_bytes", 1, MAX_RESPONSE_BYTES)
          @connect_timeout_s = validate_connect_timeout!(declaration["connect_timeout_s"])
          @redirect_max_hops = bounded_integer!(declaration["redirect_max_hops"], "redirect_max_hops", MIN_REDIRECT_HOPS, MAX_REDIRECT_HOPS)
          @circuit = validate_circuit!(declaration["circuit"]).freeze
          @credential_refs = validate_credential_refs!(declaration["credential_refs"]).freeze
          freeze
        end

        # --- policy queries -------------------------------------------------

        def allowlisted_host?(host)
          @allowlisted_hosts.include?(normalize_host(host))
        end

        # The per-hop range check: any spelling of a loopback, private,
        # link-local, unspecified, multicast, or otherwise non-routable address
        # is refused when `deny_private_ranges` is set (P17 §4 / W3). IP
        # literals are normalized (IPv4-mapped, decimal/hex/octal) BEFORE
        # classification so an exotic spelling cannot slip past an IPv4-only
        # classifier (P17-A1).
        #
        # Fail-closed (P17 critic finding 1): an address string that cannot be
        # canonically classified — dotted-short "127.1", leading-zero
        # "127.000.000.001", hex-octet "0x7f.0.0.1" — is REFUSED when
        # deny_private_ranges is set. The OS resolver interprets those
        # spellings as loopback/private forms (verified: "127.1" dials
        # 127.0.0.1, "10.1"/"192.168.1" dial RFC1918, "169.254.1" dials
        # link-local), so "unclassifiable" must never mean "public". Legitimate
        # DNS resolutions always yield canonical forms, so this never refuses a
        # real allowlisted flow.
        def private_range?(address)
          return false unless @deny_private_ranges

          ip = classify_address(address)
          return true if ip.nil?

          refused_private_range?(ip)
        end

        # Neutralizes exotic spellings of an address string to a canonical
        # `IPAddr` (or nil when it is not a parseable address at all).
        def classify_address(address)
          text = String(address)
          return nil if text.empty?

          text = text.sub(/%[0-9A-Za-z.]+$/, "") if text.include?("%")
          text = normalize_ipv4_mapped(text)
          text = normalize_numeric_ipv4(text) if NUMERIC_IP_PATTERN.match?(text)
          IPAddr.new(text)
        rescue IPAddr::InvalidAddressError, ArgumentError
          nil
        end

        # The v1 config rule: a bare IP literal in any spelling is never an
        # allowlisted host.
        def ip_literal?(host)
          return false if host.include?(".")

          IPV6_PATTERN.match?(host) || NUMERIC_IP_PATTERN.match?(host)
        end

        def validate_request_bytes!(arguments)
          query = arguments["query"]
          bytes = query.is_a?(String) ? query.bytesize : 0
          return bytes if bytes <= max_request_bytes

          raise Tamoz::Mcp::ToolArgumentError,
                "the websearch query exceeds the egress max_request_bytes " \
                "bound of #{max_request_bytes}"
        end

        def operator_authority? = "owner"

        private

        def validate_declaration_shape!(declaration)
          unless declaration.is_a?(Hash)
            raise ValidationError, "websearch egress declaration must be a mapping"
          end

          known = %w[
            allowlisted_hosts schemes deny_private_ranges max_request_bytes
            max_response_bytes connect_timeout_s redirect_max_hops circuit credential_refs
          ]
          unknown = declaration.keys - known
          return if unknown.empty?

          raise ValidationError, "websearch egress declaration has unknown fields #{unknown.sort.inspect}"
        end

        def validate_schemes!(schemes)
          unless schemes == SCHEMES
            raise ValidationError, "egress.schemes must be exactly #{SCHEMES.inspect} in v1"
          end

          schemes.dup.freeze
        end

        def validate_deny_private_ranges!(deny)
          unless deny == true || deny == false
            raise ValidationError, "egress.deny_private_ranges must be true or false"
          end

          deny
        end

        def validate_connect_timeout!(timeout)
          unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? &&
                 timeout <= MAX_CONNECT_TIMEOUT_S
            raise ValidationError, "egress.connect_timeout_s must be a positive finite number of at most #{MAX_CONNECT_TIMEOUT_S}"
          end

          timeout.to_f
        end

        def validate_hosts!(hosts)
          unless hosts.is_a?(Array) && !hosts.empty? &&
                 hosts.all? { |host| host.is_a?(String) } && hosts.uniq == hosts
            raise ValidationError,
                  "egress.allowlisted_hosts must be a non-empty array of distinct strings"
          end

          hosts.map { |host| validate_host!(host) }.freeze
        end

        def validate_host!(host)
          reject_credential_shaped_host!(host)
          reject_invalid_host_shape!(host)
          reject_ip_literal_host!(host)
          assert_absolute_dns_name!(host)

          host
        end

        def reject_credential_shaped_host!(host)
          return unless CREDENTIAL_NAME_PATTERN.match?(host)

          raise ValidationError,
                "egress.allowlisted_hosts entry #{host.inspect} is credential-shaped"
        end

        def reject_invalid_host_shape!(host)
          if host.empty? || host.bytesize > 253
            raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} must be an absolute DNS name"
          end
          if host.include?("*")
            raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} contains a wildcard; v1 allows exact FQDNs only"
          end
          if host.include?("/") || host.include?("@") || host.include?(":") || host.match?(/\s/)
            raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} must be a bare hostname"
          end
          return if host == host.downcase

          raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} must be lowercase"
        end

        def reject_ip_literal_host!(host)
          return unless IPV4_PATTERN.match?(host) || ip_literal?(host)

          raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} is an IP literal; v1 allows exact FQDNs only"
        end

        def assert_absolute_dns_name!(host)
          labels = host.split(".")
          unless labels.length >= 2 && labels.none?(&:empty?) &&
                 labels.all? { |label| label.bytesize <= 63 && HOST_LABEL_PATTERN.match?(label) }
            raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} is not a valid absolute DNS name"
          end
          return unless labels.last.match?(/\A\d+\z/)

          raise ValidationError, "egress.allowlisted_hosts entry #{host.inspect} must not end in a numeric label"
        end

        def refused_private_range?(ip)
          refused = ip.loopback? || ip.private? || ip.link_local?
          if ip.ipv4?
            refused ||= refused_private_ipv4?(ip)
          elsif ip.ipv6?
            refused ||= refused_private_ipv6?(ip)
          end
          refused
        end

        def refused_private_ipv4?(ip)
          octets = ip.to_s.split(".").map(&:to_i)
          first, second = octets
          # 0.0.0.0/8 (this-host / unspecified), 224.0.0.0/4 (multicast),
          # 255.255.255.255 (limited broadcast).
          refused = first == 0 || first.between?(224, 239) || ip.to_s == "255.255.255.255"
          # 100.64.0.0/10 (CGNAT), 192.0.0.0/24, 198.18.0.0/15, 240.0.0.0/4 —
          # reserved blocks no outbound search provider legitimately lives in.
          refused ||
            (first == 100 && second.between?(64, 127)) ||
            (first == 192 && second == 0) ||
            (first == 198 && second.between?(18, 19)) ||
            first >= 240
        end

        def refused_private_ipv6?(ip)
          # ff00::/8 (multicast) and ::/128 (unspecified) — IPAddr has no
          # predicates for either, so the leading hextet is checked directly.
          ip.to_s.start_with?("ff") || ip.to_s == "::"
        end

        def validate_circuit!(circuit)
          unless circuit.is_a?(Hash)
            raise ValidationError, "egress.circuit must be a mapping"
          end
          unknown = circuit.keys - %w[threshold scope_type budget_breach]
          unless unknown.empty?
            raise ValidationError, "egress.circuit has unknown fields #{unknown.sort.inspect}"
          end
          unless circuit["scope_type"] == SCOPE_TYPE
            raise ValidationError, "egress.circuit.scope_type must be #{SCOPE_TYPE.inspect}"
          end
          threshold = bounded_integer!(circuit["threshold"], "egress.circuit.threshold", 1, MAX_CIRCUIT_THRESHOLD)
          budget_breach = circuit["budget_breach"]
          unless budget_breach == true || budget_breach == false
            raise ValidationError, "egress.circuit.budget_breach must be true or false"
          end

          {"threshold" => threshold, "scope_type" => SCOPE_TYPE, "budget_breach" => budget_breach}
        end

        def validate_credential_refs!(refs)
          unless refs.is_a?(Array) && refs.uniq == refs &&
                 refs.all? { |name| name.is_a?(String) && CREDENTIAL_REF_PATTERN.match?(name) }
            raise ValidationError,
                  "egress.credential_refs must be distinct names matching #{CREDENTIAL_REF_PATTERN.inspect}; names only"
          end

          refs
        end

        def bounded_integer!(value, field, minimum, maximum)
          unless value.is_a?(Integer) && value.between?(minimum, maximum)
            raise ValidationError, "egress.#{field} must be an integer between #{minimum} and #{maximum}"
          end

          value
        end

        def normalize_host(host)
          String(host).downcase
        end

        # `::ffff:127.0.0.1` and the hex-octet form `::ffff:7f00:1` both denote
        # the IPv4-mapped address; map to the bare IPv4 before classification.
        def normalize_ipv4_mapped(text)
          mapped = text.match(/\A::ffff:(\d{1,3}(?:\.\d{1,3}){3})\z/)
          return mapped[1] if mapped

          hex_mapped = text.match(/\A::ffff:([0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){1,3})\z/)
          return text unless hex_mapped

          octets = hex_mapped[1].split(":").flat_map do |group|
            number = group.to_i(16)
            [(number >> 8) & 0xff, number & 0xff]
          end
          octets.join(".")
        end

        # `2130706433` (127.0.0.1), `0x7f000001`, `017700000001` — one 32-bit
        # integer spelled in decimal/hex/octal.
        def normalize_numeric_ipv4(text)
          number = if text.start_with?("0x", "0X")
                     text.to_i(16)
                   elsif text.match?(/\A0[0-7]+\z/)
                     text.to_i(8)
                   else
                     text.to_i(10)
                   end
          return text if number > 0xffff_ffff

          [24, 16, 8, 0].map { |shift| (number >> shift) & 0xff }.join(".")
        end
      end
    end
  end
end
