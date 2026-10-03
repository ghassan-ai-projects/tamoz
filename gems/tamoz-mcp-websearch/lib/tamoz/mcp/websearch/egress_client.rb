# frozen_string_literal: true

require "net/http"
require "uri"

module Tamoz
  module Mcp
    module Websearch
      # A connection/redirect target was refused by the egress policy — host
      # off-allowlist, non-https scheme, a private-range or unresolvable
      # address, or a redirect off the allowlist. Terminal: nothing was dialed
      # for the refused hop (P17 §8 failure model).
      class EgressPolicyError < Tamoz::Mcp::ToolPolicyError
        CATEGORY = "mcp_egress_policy"
        USER_VISIBLE = true
        SAFE_MESSAGE = "A websearch egress policy violation was refused."

        def repairable? = false
      end

      # The redirect chain exceeded the declared hop bound (`redirect_max_hops`).
      # Terminal; no further hop is followed (W4 / P17-A1).
      class RedirectHopLimitError < EgressPolicyError
        CATEGORY = "mcp_redirect_hop_limit"
        SAFE_MESSAGE = "A websearch redirect chain exceeded the allowed hop count."
      end

      # Per-hop websearch transport (P17 §4, correction 3). Resolve →
      # range-check → allowlist-check runs on EVERY connection AND every
      # redirect target — never once before connecting, because a TTL-0
      # rebinding DNS defeats a single pre-connect check. The validated address
      # is the address actually passed to the connector (the socket dialer):
      # there is no second DNS lookup at dial time, so there is no
      # check-to-connect resolution race. TLS still verifies the allowlisted
      # hostname (SNI/certificate), so pinning the IP never bypasses
      # certificate identity. Redirect hop bound comes from the policy; no
      # credential/header is forwarded across hosts.
      #
      # This class is the operator-side adapter's HTTP stack — it lives in the
      # process Tamoz supervises, never in Tamoz's own process (correction 2).
      # :reek:TooManyConstants :reek:TooManyInstanceVariables :reek:TooManyMethods -- the one per-hop client.
      class EgressClient
        DEFAULT_PORT = 443
        REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
        MAX_REDIRECT_LOCATION_BYTES = 2048
        CREDENTIAL_HEADER_NAMES = %w[authorization proxy-authorization cookie].freeze
        # The only request headers a redirect to another host keeps: any other may carry a provider's credential.
        CROSS_HOST_HEADERS = %w[accept accept-language user-agent].freeze
        # `:allowlist` reaches only the declared hosts; `:public` (the page reader) reaches any public FQDN, with every
        # other per-hop check unchanged.
        REACHES = %i[allowlist public].freeze
        READER_MAX_RESPONSE_BYTES = 2 * 1024 * 1024

        # The bounded outcome of one fetch. `truncated` is true when the body
        # was cut at `max_response_bytes` (the caller surfaces it as evidence
        # the response exceeded the declared budget).
        Result = Data.define(:status, :headers, :body, :truncated)

        attr_reader :policy

        # Frozen copy: the dial audit trail must not be rewritable through the reader.
        def dials = @dials.dup.freeze

        # `resolver:` resolves a hostname to candidate address strings
        # (`call(host) -> Array<String>`). `connector:` performs the exchange
        # against the PINNED address (`call(pinned_ip:, host:, path:, port:,
        # timeout:, headers:, body:) -> {status:, headers:, body:}`) and is the
        # dial-spy seam the W3 suite records. `path` carries the request path
        # AND its query — it is the request, so a connector that ignores it is
        # asking a different question than the caller asked. Both default to
        # real implementations.
        # :reek:ControlParameter
        def initialize(policy:, resolver: nil, connector: nil, reach: :allowlist, max_response_bytes: nil)
          unless policy.is_a?(EgressPolicy)
            raise ValidationError, "policy must be a Tamoz::Mcp::Websearch::EgressPolicy"
          end

          @policy = policy
          @reach = checked_reach(reach)
          @max_response_bytes = response_bound(max_response_bytes || policy.max_response_bytes)
          @resolver = resolver || default_resolver
          @connector = connector || default_connector
          @dials = []
          freeze
        end

        # One governed fetch from an https URL. Returns a bounded `Result`;
        # raises `EgressPolicyError`/`RedirectHopLimitError` per the failure
        # model. `headers:` are the caller's request headers (never logged);
        # `body:` is the request body (bounded by the policy's request bound).
        def fetch(url, headers: {}, body: nil)
          target = initial_target(url, headers, body)
          hops = 0
          loop do
            response = dial(target)
            return bounded_result(response) unless redirect?(response)

            hops += 1
            enforce_hop_limit!(hops)
            target = redirect_target(response, current: target)
          end
        end

        private

        def dial(target)
          pinned = pin_address(target.fetch(:host))
          @dials << pinned
          @connector.call(
            pinned_ip: pinned,
            host: target.fetch(:host),
            # Path + query is the request itself (contract on initialize), recomputed every hop.
            path: target.fetch(:path),
            port: DEFAULT_PORT,
            timeout: policy.connect_timeout_s,
            headers: target.fetch(:headers),
            body: target[:body]
          )
        end

        def enforce_hop_limit!(hops)
          return if hops <= policy.redirect_max_hops

          raise RedirectHopLimitError,
                "the websearch redirect chain exceeded the declared bound of #{policy.redirect_max_hops} hops"
        end

        def checked_reach(reach)
          raise ValidationError, "reach must be one of #{REACHES.join(', ')}" unless REACHES.include?(reach)
          if reach == :public && !(policy.deny_private_ranges && policy.page_reads == "public")
            raise ValidationError, "the public reach needs deny_private_ranges and page_reads: public"
          end

          reach
        end

        def response_bound(bytes)
          return bytes if bytes.is_a?(Integer) && (1..READER_MAX_RESPONSE_BYTES).cover?(bytes)

          raise ValidationError, "max_response_bytes must be 1 to #{READER_MAX_RESPONSE_BYTES}"
        end

        def initial_target(url, headers, body)
          uri = upgraded(parse_url(url))
          validate_scheme!(uri)
          host = validate_host!(uri.host)
          validate_port!(uri)
          if body && body.bytesize > policy.max_request_bytes
            raise EgressPolicyError,
                  "the websearch request body exceeds the declared max_request_bytes " \
                  "bound of #{policy.max_request_bytes}"
          end

          {host:, path: request_path(uri), headers: headers.dup.freeze, body: body&.dup&.freeze}
        end

        # A redirect Location is refetched through the FULL resolve→classify→
        # pin→dial sequence; the host must pass the same scheme + allowlist
        # checks as the initial target. When the authority changes, every
        # credential-carrying header is dropped (invariant 24 — a credential
        # never leaves the trust boundary through a redirect).
        def redirect_target(response, current:)
          location = response.fetch("headers").fetch("location", nil)
          location = location.dup.force_encoding(Encoding::UTF_8)
          unless location.is_a?(String) && location.valid_encoding? &&
                 location.bytesize <= MAX_REDIRECT_LOCATION_BYTES
            raise EgressPolicyError, "the websearch redirect Location is malformed"
          end

          uri = begin
            upgraded(URI.join("https://#{current.fetch(:host)}#{current.fetch(:path)}", location))
          rescue URI::InvalidURIError
            raise EgressPolicyError, "the websearch redirect Location is malformed"
          end
          validate_scheme!(uri)
          host = validate_host!(uri.host)
          validate_port!(uri)
          headers = current.fetch(:headers)
          if host != current.fetch(:host)
            headers = headers.select { |name, _| CROSS_HOST_HEADERS.include?(name.downcase) }.freeze
          end

          {host:, path: request_path(uri), headers:, body: nil}
        end

        def parse_url(url)
          text = String(url).dup.force_encoding(Encoding::UTF_8)
          raise EgressPolicyError, "the websearch target URL is malformed" unless text.valid_encoding?

          URI.parse(text)
        rescue URI::InvalidURIError
          raise EgressPolicyError, "the websearch target URL is malformed"
        end

        # A public page named over http is asked for over https; nothing is ever fetched over http.
        def upgraded(uri)
          return uri unless @reach == :public && uri.instance_of?(URI::HTTP) && uri.port == URI::HTTP::DEFAULT_PORT

          URI::HTTPS.build(host: uri.host, path: uri.path, query: uri.query)
        end

        def validate_scheme!(uri)
          return if uri.is_a?(URI::HTTPS) && uri.scheme == "https"

          raise EgressPolicyError,
                "the websearch target scheme must be https (v1 allows https only)"
        end

        def validate_host!(host)
          if host.nil? || host.empty?
            raise EgressPolicyError, "the websearch target has no host"
          end
          # v1 config rule: an IP literal in any spelling is never an
          # allowlisted host (the per-hop address range check is the second
          # layer). A redirect Location pointing at a metadata-address spelling
          # is refused here, before any resolution.
          if policy.ip_literal?(host) || host.match?(EgressPolicy::IPV4_PATTERN)
            raise EgressPolicyError,
                  "the websearch target host #{host.inspect} is an IP literal; " \
                  "v1 allows exact allowlisted FQDNs only"
          end
          unless @reach == :public || policy.allowlisted_host?(host)
            raise EgressPolicyError,
                  "the websearch target host #{host.inspect} is not allowlisted"
          end

          host
        end

        def validate_port!(uri)
          return if uri.port.nil? || uri.port == DEFAULT_PORT

          raise EgressPolicyError, "the websearch target must use the default https port 443"
        end

        def request_path(uri)
          path = uri.request_uri
          raise EgressPolicyError, "the websearch target path is malformed" if path.nil?

          path
        end

        def pin_address(host)
          addresses = begin
            @resolver.call(host)
          rescue StandardError
            nil
          end
          unless addresses.is_a?(Array) && !addresses.empty?
            raise EgressPolicyError,
                  "the websearch target host #{host.inspect} could not be resolved"
          end

          addresses.each do |address|
            next if policy.private_range?(address)

            # The first acceptable candidate is pinned; `dials` records it for
            # audit and the connector receives exactly this value.
            return address
          end
          raise EgressPolicyError,
                "the websearch target host #{host.inspect} resolved only to refused " \
                "addresses"
        end

        def redirect?(response)
          status = response.fetch("status")
          REDIRECT_STATUSES.include?(status) && response.fetch("headers").key?("location")
        end

        def bounded_result(response)
          status = response.fetch("status")
          headers = response.fetch("headers")
          body = String(response.fetch("body") || "")
          truncated = false
          if body.bytesize > @max_response_bytes
            body = body.byteslice(0, @max_response_bytes).scrub("").rstrip
            truncated = true
          end
          Result.new(status:, headers: headers.dup.freeze, body: body.freeze, truncated:)
        end

        def default_resolver
          require "resolv"

          lambda do |host|
            Resolv.getaddresses(host)
          end
        end

        # Real connector: Net::HTTP over the PINNED address with the hostname as
        # the TLS SNI / certificate identity. `ipaddr=` selects the connect
        # address while `address` stays the allowlisted hostname, so the
        # validated IP is what is dialed and certificate verification still
        # checks the hostname the operator allowlisted. The body is streamed and
        # cut past the response bound, identity-encoded (no gzip bomb), and the
        # whole read stays inside a deadline.
        def default_connector
          limit = @max_response_bytes
          lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
            http = Net::HTTP.new(host, port)
            http.ipaddr = pinned_ip
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            http.open_timeout = timeout
            http.read_timeout = timeout
            # A body decides the verb. `Net::HTTP::Get` does not permit one
            # (`request_body_permitted?` is false), so assigning `request.body`
            # on a GET dropped it silently — the query never reached the
            # provider. A request that carries a body is a POST.
            request = (body ? Net::HTTP::Post : Net::HTTP::Get).new(path)
            headers.merge("Accept-Encoding" => "identity").each { |name, value| request[name] = value }
            request.body = body if body
            http.start { |connection| bounded_exchange(connection, request, limit, timeout * 3) }
          end
        end

        # :reek:DuplicateMethodCall :reek:LongParameterList :reek:NestedIterators :reek:TooManyStatements
        # :reek:UtilityFunction
        def bounded_exchange(connection, request, limit, seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          connection.request(request) do |response|
            received = +""
            response.read_body do |chunk|
              received << chunk
              break if received.bytesize > limit || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            end
            return {"status" => response.code.to_i, "headers" => response.each_header.to_h.freeze, "body" => received}
          end
        end
      end
    end
  end
end
