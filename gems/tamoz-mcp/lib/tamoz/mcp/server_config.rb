# frozen_string_literal: true

module Tamoz
  module Mcp
    # Immutable admission configuration for one MCP server (P10 §4). Validated
    # fail-closed at construction with typed `ValidationError` rejections; nothing
    # is spawned here. The caller renders `#describe` for operator confirmation
    # before adoption, exactly like the P8 profile/check preview.
    ServerConfig = Data.define(
      :server_id,          # SERVER_ID_PATTERN; the ONLY source of source qualification
      :transport,          # :stdio (v1 only; :http is reserved and rejected)
      :command,            # absolute path to the executable
      :arguments,          # frozen argv, no shell, no metacharacters
      :env_allowlist,      # names the child may inherit; values never logged
      :credential_refs,    # env var names the child receives from the operator env
      :working_directory,  # absolute, must exist, not the agent workspace root
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
      # C0 controls plus DEL. Newlines in argv corrupt every downstream log,
      # prompt, and receipt that renders the command.
      CONTROL_CHARACTER_PATTERN = /[\x00-\x1f\x7f]/

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
          unless max_concurrent.is_a?(Integer) && max_concurrent >= 1
            raise ValidationError, "budgets.max_concurrent must be an integer >= 1"
          end
          unless stderr_bytes.is_a?(Integer) && stderr_bytes.positive?
            raise ValidationError, "budgets.stderr_bytes must be a positive integer"
          end

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
      end

      def initialize(
        server_id:,
        transport:,
        command:,
        working_directory:,
        arguments: [],
        env_allowlist: [],
        credential_refs: [],
        protocol_range: DEFAULT_PROTOCOL_RANGE,
        primitives: DEFAULT_PRIMITIVES,
        budgets: Budgets.new,
        workspace_root: nil
      )
        server_id = validate_server_id!(server_id)
        transport = validate_transport!(transport)
        workspace = validate_workspace_root!(workspace_root)
        command = validate_command!(command, workspace)
        arguments = validate_arguments!(arguments)
        env_allowlist = validate_env_allowlist!(env_allowlist)
        credential_refs = validate_credential_refs!(credential_refs)
        working_directory = validate_working_directory!(working_directory, workspace)
        protocol_range = validate_protocol_range!(protocol_range)
        primitives = validate_primitives!(primitives)
        unless budgets.is_a?(Budgets)
          raise ValidationError, "budgets must be a Tamoz::Mcp::ServerConfig::Budgets"
        end

        super(
          server_id:, transport:, command:, arguments:, env_allowlist:,
          credential_refs:, working_directory:, protocol_range:, primitives:,
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
        if value == :http
          raise ValidationError, "transport :http is reserved; only :stdio is supported in v1"
        end
        unless value == :stdio
          raise ValidationError, "transport must be :stdio, got #{value.inspect}"
        end

        value
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
        if workspace
          real = File.realpath(value)
          if real == workspace || real.start_with?("#{workspace}#{File::SEPARATOR}")
            raise ValidationError, "command must not be inside the agent workspace: #{value.inspect}"
          end
        end

        value.dup.freeze
      end

      def validate_arguments!(value)
        unless value.is_a?(Array)
          raise ValidationError, "arguments must be an array of strings"
        end

        value.map do |element|
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
        end.freeze
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
