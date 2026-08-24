# frozen_string_literal: true

require "ipaddr"
require "uri"

module Tamoz
  module Mcp
    # Immutable admission configuration for one MCP server (P10 §4). Validated
    # fail-closed at construction with typed `ValidationError` rejections; nothing
    # is spawned here. The caller renders `#describe` for operator confirmation
    # before adoption, exactly like the P8 profile/check preview.
    ServerConfig = Data.define(
      :server_id,          # SERVER_ID_PATTERN; the ONLY source of source qualification
      :transport,          # :stdio or :http (Streamable HTTP)
      :command,            # absolute path to the executable for stdio
      :arguments,          # frozen argv, no shell, no metacharacters
      :env_allowlist,      # names the child may inherit; values never logged
      :credential_refs,    # env var names resolved for the child or HTTP headers
      :working_directory,  # absolute for stdio, nil for HTTP
      :endpoint,           # absolute HTTP(S) endpoint for HTTP
      :allow_insecure_http, # explicit private-network HTTP opt-in
      :headers, # non-secret static HTTP headers
      :credential_headers, # HTTP header => credential ref name
      :protocol_range,     # [min, max], default ["2025-11-25", "2026-07-28"]
      :primitives,         # subset of %i[tools resources prompts]; default [:tools]
      :budgets             # Budgets
    ) do
      SERVER_ID_PATTERN = /\A[a-z][a-z0-9_-]{0,63}\z/
      PROTOCOL_VERSION_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
      DEFAULT_PROTOCOL_RANGE = ["2025-11-25", "2026-07-28"].freeze
      PRIMITIVES = %i[tools resources prompts].freeze
      DEFAULT_PRIMITIVES = [:tools].freeze
      ENV_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      CREDENTIAL_REF_PATTERN = /\ATAMOZ_[A-Z0-9_]+\z/
      MAX_ARGUMENT_BYTES = 4096

      # The argv/metacharacter rules below deliberately DUPLICATE the P8 profile
      # loader's argv policy: a configured server command is an exact argv executed
      # without a shell, so the same defence-in-depth scan applies. `tamoz-mcp`
      # must not depend on `tamoz-agent`, so the patterns are repeated here
      # instead of imported (see docs/P10_MCP_PLAN.md §3).
      SHELL_METACHARACTER_PATTERN = /[$;|><`*&]/

      # Deliberate duplication of the P8-E credential-env rule from
      # `Tamoz::Agent::Toolbox` (see docs/P10_MCP_PLAN.md §3): an inherited
      # credential variable is one `printenv` away from every place a credential
      # must never appear, and `tamoz-mcp` must not depend on `tamoz-agent`.
      CREDENTIAL_ENV_PATTERN = /(?:\A|_)(?:
        API_?KEYS? | ACCESS_?KEYS? | SECRET_?KEYS? | PRIVATE_?KEYS? | SESSION_?KEYS? |
        TOKENS? | SECRETS? | PASSWORD | PASSWD | CREDENTIALS? | PASSPHRASE
      )(?:\z|_)/x
      CREDENTIAL_ENV_NAMES = %w[
        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
        ANTHROPIC_API_KEY DEEPSEEK_API_KEY GEMINI_API_KEY MISTRAL_API_KEY OLLAMA_API_KEY
        OPENAI_API_KEY OPENROUTER_API_KEY PERPLEXITY_API_KEY XAI_API_KEY
      ].freeze

      Budgets = Data.define(
        :max_catalog_entries, :max_description_bytes, :max_output_bytes,
        :connect_timeout, :request_timeout, :max_concurrent, :idle_timeout,
        :max_lifetime, :stderr_bytes
      ) do
        MAX_CATALOG_ENTRIES = 256
        MAX_DESCRIPTION_BYTES = 4096
        MAX_OUTPUT_BYTES = 64 * 1024

        def initialize(
          max_catalog_entries: 256,
          max_description_bytes: 4096,
          max_output_bytes: MAX_OUTPUT_BYTES,
          connect_timeout: 10.0,
          request_timeout: 30.0,
          max_concurrent: 4,
          idle_timeout: 300.0,
          max_lifetime: 3600.0,
          stderr_bytes: 8 * 1024
        )
          bounded_integer!("max_catalog_entries", max_catalog_entries, MAX_CATALOG_ENTRIES)
          bounded_integer!("max_description_bytes", max_description_bytes, MAX_DESCRIPTION_BYTES)
          bounded_integer!("max_output_bytes", max_output_bytes, MAX_OUTPUT_BYTES)
          positive_finite!("connect_timeout", connect_timeout)
          positive_finite!("request_timeout", request_timeout)
          positive_finite!("idle_timeout", idle_timeout)
          positive_finite!("max_lifetime", max_lifetime)
          positive_integer!("max_concurrent", max_concurrent)
          positive_integer!("stderr_bytes", stderr_bytes)

          super
        end

        private

        def bounded_integer!(name, value, cap)
          unless value.is_a?(Integer) && value >= 1 && value <= cap
            raise ValidationError, "budgets.#{name} must be an integer between 1 and #{cap}"
          end
        end

        def positive_finite!(name, value)
          unless value.is_a?(Numeric) && value.finite? && value.positive?
            raise ValidationError, "budgets.#{name} must be positive and finite"
          end
        end

        def positive_integer!(name, value)
          unless value.is_a?(Integer) && value.positive?
            raise ValidationError, "budgets.#{name} must be a positive integer"
          end
        end
      end

      def initialize(
        server_id:,
        transport:,
        command: nil,
        working_directory: nil,
        endpoint: nil,
        allow_insecure_http: false,
        arguments: [],
        env_allowlist: [],
        credential_refs: [],
        headers: {},
        credential_headers: {},
        protocol_range: DEFAULT_PROTOCOL_RANGE,
        primitives: DEFAULT_PRIMITIVES,
        budgets: Budgets.new,
        workspace_root: nil
      )
        server_id = validate_server_id!(server_id)
        transport = validate_transport!(transport)
        workspace = validate_workspace_root!(workspace_root)
        arguments = validate_arguments!(arguments)
        env_allowlist = validate_env_allowlist!(env_allowlist)
        credential_refs = validate_credential_refs!(credential_refs)
        allow_insecure_http = validate_allow_insecure_http!(allow_insecure_http)
        endpoint = validate_endpoint!(endpoint, transport, allow_insecure_http)
        headers = validate_headers!(headers)
        credential_headers = validate_credential_headers!(credential_headers, credential_refs, headers)
        command, working_directory = validate_process_surface!(
          transport, command, arguments, env_allowlist, working_directory, workspace
        )
        protocol_range = validate_protocol_range!(protocol_range)
        primitives = validate_primitives!(primitives)
        unless budgets.is_a?(Budgets)
          raise ValidationError, "budgets must be a Tamoz::Mcp::ServerConfig::Budgets"
        end

        super(
          server_id:, transport:, command:, arguments:, env_allowlist:,
          credential_refs:, working_directory:, endpoint:, allow_insecure_http:, headers:, credential_headers:,
          protocol_range:, primitives:,
          budgets:
        )
      end

      # Exact preview for operator confirmation: command, argv, and env NAMES
      # only. Values never appear here — `env_allowlist` and `credential_refs`
      # carry names by construction and resolution happens in the caller.
      def describe
        {
          "server_id" => server_id,
          "transport" => transport.to_s,
          "command" => command,
          "argv" => [command, *arguments],
          "env_allowlist" => env_allowlist.dup,
          "credential_refs" => credential_refs.dup,
          "working_directory" => working_directory,
          "endpoint" => endpoint,
          "allow_insecure_http" => allow_insecure_http,
          "headers" => headers.keys,
          "credential_headers" => credential_headers.keys,
          "protocol_range" => protocol_range.dup,
          "primitives" => primitives.map(&:to_s),
          "budgets" => {
            "max_catalog_entries" => budgets.max_catalog_entries,
            "max_description_bytes" => budgets.max_description_bytes,
            "max_output_bytes" => budgets.max_output_bytes,
            "connect_timeout" => budgets.connect_timeout,
            "request_timeout" => budgets.request_timeout,
            "max_concurrent" => budgets.max_concurrent,
            "idle_timeout" => budgets.idle_timeout,
            "max_lifetime" => budgets.max_lifetime,
            "stderr_bytes" => budgets.stderr_bytes
          }
        }.freeze
      end

      def self.credential_env_name?(name)
        upper = String(name).upcase
        CREDENTIAL_ENV_NAMES.include?(upper) || CREDENTIAL_ENV_PATTERN.match?(upper)
      end

      private

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

      def validate_allow_insecure_http!(value)
        return value if [true, false].include?(value)

        raise ValidationError, "allow_insecure_http must be a boolean"
      end

      def validate_endpoint!(value, transport, allow_insecure_http)
        return nil if transport == :stdio && value.nil?

        uri = parse_endpoint_uri!(value, transport)
        validate_endpoint_security!(uri, allow_insecure_http)
        value.dup.freeze
      end

      def parse_endpoint_uri!(value, transport)
        unless transport == :http && value.is_a?(String) && !value.empty?
          raise ValidationError, "endpoint is required for :http and must be an absolute URL"
        end

        uri = URI.parse(value)
        unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil? && uri.fragment.nil?
          raise ValidationError, "endpoint must be an absolute http(s) URL without userinfo or fragments"
        end

        uri
      rescue URI::InvalidURIError
        raise ValidationError, "endpoint must be an absolute http(s) URL"
      end

      def validate_endpoint_security!(uri, allow_insecure_http)
        return unless uri.scheme == "http" && !loopback_host?(uri.host) &&
                      !(allow_insecure_http && private_ip_host?(uri.host))

        raise ValidationError, "endpoint must use https unless it targets loopback"
      end

      def loopback_host?(host)
        %w[localhost 127.0.0.1 ::1].include?(host.downcase.delete("[]"))
      end

      def private_ip_host?(host)
        IPAddr.new(host.delete("[]")).private?
      rescue IPAddr::InvalidAddressError
        false
      end

      def validate_headers!(value)
        unless value.is_a?(Hash)
          raise ValidationError, "headers must be a mapping of non-secret names to strings"
        end

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
          raise ValidationError, "credential_headers must map HTTP header names to credential refs"
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
        unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/)
          raise ValidationError, "HTTP header names must be valid strings"
        end
      end

      def validate_header_value!(value)
        unless value.is_a?(String) && value.bytesize <= 4096 && !CONTROL_CHARACTER_PATTERN.match?(value)
          raise ValidationError, "HTTP header values must be bounded strings without control characters"
        end
      end

      def credential_header_name?(name)
        name.match?(/authorization|cookie|token|secret|api[-_]?key|password/i)
      end

      def validate_process_surface!(transport, command, arguments, env_allowlist, working_directory, workspace)
        if transport == :http
          unless command.nil? && arguments.empty? && env_allowlist.empty? && working_directory.nil?
            raise ValidationError,
                  "HTTP MCP servers cannot configure a command, argv, environment, or working directory"
          end

          return [nil, nil]
        end

        [validate_command!(command, workspace), validate_working_directory!(working_directory, workspace)]
      end

      def validate_workspace_root!(value)
        return nil if value.nil?
        unless value.is_a?(String) && Pathname.new(value).absolute?
          raise ValidationError, "workspace_root must be an absolute path when supplied"
        end

        File.realpath(value)
      rescue Errno::ENOENT
        raise ValidationError, "workspace_root does not exist: #{value.inspect}"
      end

      # Invariant 35: repository content is not authority. The executable must be
      # operator-owned — absolute, executable, not a symlink, and never inside the
      # agent workspace.
      def validate_command!(value, workspace)
        validate_command_path!(value)
        validate_command_outside_workspace!(value, workspace) if workspace

        value.dup.freeze
      end

      def validate_command_path!(value)
        unless value.is_a?(String) && Pathname.new(value).absolute?
          raise ValidationError, "command must be an absolute path, got #{value.inspect}"
        end
        if File.symlink?(value)
          raise ValidationError, "command must not be a symlink: #{value.inspect}"
        end
        unless File.file?(value)
          raise ValidationError, "command does not exist or is not a file: #{value.inspect}"
        end
        unless File.executable?(value)
          raise ValidationError, "command is not executable: #{value.inspect}"
        end
      end

      def validate_command_outside_workspace!(value, workspace)
        real = File.realpath(value)
        return unless real == workspace || real.start_with?("#{workspace}#{File::SEPARATOR}")

        raise ValidationError, "command must not be inside the agent workspace: #{value.inspect}"
      end

      def validate_arguments!(value)
        unless value.is_a?(Array)
          raise ValidationError, "arguments must be an array of strings"
        end

        value.map { |element| validate_argument_element!(element) }.freeze
      end

      def validate_argument_element!(element)
        unless element.is_a?(String)
          raise ValidationError, "arguments elements must be strings, got #{element.class}"
        end
        if element.include?("\x00")
          raise ValidationError, "arguments element contains a NUL byte"
        end
        if CONTROL_CHARACTER_PATTERN.match?(element)
          raise ValidationError, "arguments element contains a control character"
        end
        if element.bytesize > MAX_ARGUMENT_BYTES
          raise ValidationError, "arguments element exceeds #{MAX_ARGUMENT_BYTES} bytes"
        end
        if SHELL_METACHARACTER_PATTERN.match?(element)
          raise ValidationError,
                "arguments element #{element.inspect} contains shell metacharacters"
        end

        element.dup.freeze
      end

      # The allowlist names variables the child may inherit. A credential-shaped
      # name here would defeat the P8-E rule that credentials reach a child only
      # through explicit `credential_refs`, so it is rejected outright.
      def validate_env_allowlist!(value)
        unless value.is_a?(Array)
          raise ValidationError, "env_allowlist must be an array of environment variable names"
        end

        value.map do |name|
          unless name.is_a?(String) && ENV_NAME_PATTERN.match?(name)
            raise ValidationError, "env_allowlist entries must be valid names, got #{name.inspect}"
          end
          if ServerConfig.credential_env_name?(name)
            raise ValidationError,
                  "env_allowlist entry #{name.inspect} is credential-shaped; " \
                  "use credential_refs for explicit credential names"
          end

          name.dup.freeze
        end.freeze
      end

      def validate_credential_refs!(value)
        unless value.is_a?(Array)
          raise ValidationError, "credential_refs must be an array of explicit names"
        end

        value.map do |name|
          unless name.is_a?(String) && CREDENTIAL_REF_PATTERN.match?(name)
            raise ValidationError,
                  "credential_refs entries must match #{CREDENTIAL_REF_PATTERN.inspect}, " \
                  "got #{name.inspect}"
          end

          name.dup.freeze
        end.freeze
      end

      def validate_working_directory!(value, workspace)
        unless value.is_a?(String) && Pathname.new(value).absolute?
          raise ValidationError, "working_directory must be an absolute path, got #{value.inspect}"
        end
        unless File.directory?(value)
          raise ValidationError, "working_directory does not exist: #{value.inspect}"
        end
        real = File.realpath(value)
        if workspace && real == workspace
          raise ValidationError, "working_directory must not be the agent workspace root"
        end

        value.dup.freeze
      end

      def validate_protocol_range!(value)
        unless value.is_a?(Array) && value.length == 2 &&
               value.all? { |v| v.is_a?(String) && PROTOCOL_VERSION_PATTERN.match?(v) }
          raise ValidationError,
                "protocol_range must be [min, max] of YYYY-MM-DD protocol versions"
        end
        min, max = value
        if min > max
          raise ValidationError, "protocol_range min #{min.inspect} is after max #{max.inspect}"
        end

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
    end

    # The Data.define block is instance_exec'd, so the constants above live on
    # `Tamoz::Mcp`; expose Budgets under ServerConfig as the plan names it.
    ServerConfig::Budgets = Budgets
  end
end
