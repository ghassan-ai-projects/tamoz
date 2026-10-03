# frozen_string_literal: true

require "ipaddr"
require "uri"

require_relative "budgets"
require_relative "http_admission"
require_relative "process_admission"
require_relative "server_admission"

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
      MAX_HEADER_VALUE_BYTES = 4096

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
        OPENAI_API_KEY OPENROUTER_API_KEY PERPLEXITY_API_KEY XAI_API_KEY ZAI_API_KEY
      ].freeze

      def initialize(
        server_id:, transport:, command: nil, working_directory: nil, endpoint: nil, allow_insecure_http: false,
        arguments: [], env_allowlist: [], credential_refs: [], headers: {}, credential_headers: {},
        protocol_range: DEFAULT_PROTOCOL_RANGE, primitives: DEFAULT_PRIMITIVES, budgets: Budgets.new,
        workspace_root: nil
      )
        server_id, transport = ServerAdmission.new.validate_identity!(server_id, transport)
        workspace = ProcessAdmission.new.validate_workspace_root!(workspace_root)
        arguments = ProcessAdmission.new.validate_arguments!(arguments)
        env_allowlist = ProcessAdmission.new.validate_env_allowlist!(env_allowlist)
        credential_refs = ServerAdmission.new.validate_credential_refs!(credential_refs)
        allow_insecure_http = HttpAdmission.new.validate_allow_insecure_http!(allow_insecure_http)
        endpoint = HttpAdmission.new.validate_endpoint!(endpoint, transport, allow_insecure_http)
        headers = HttpAdmission.new.validate_headers!(headers)
        credential_headers = HttpAdmission.new.validate_credential_headers!(credential_headers, credential_refs,
                                                                            headers)
        command, working_directory = ProcessAdmission.new.validate_process_surface!(
          transport:, command:, arguments:, env_allowlist:, working_directory:, workspace:
        )
        protocol_range = ServerAdmission.new.validate_protocol_range!(protocol_range)
        primitives = ServerAdmission.new.validate_primitives!(primitives)
        budgets = ServerAdmission.new.validate_budgets!(budgets)

        super(
          server_id:, transport:, command:, arguments:, env_allowlist:,
          credential_refs:, working_directory:, endpoint:, allow_insecure_http:, headers:, credential_headers:,
          protocol_range:, primitives:, budgets:
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
          "budgets" => Budgets.members.to_h { |name| [name.to_s, budgets.public_send(name)] }
        }.freeze
      end

      def self.credential_env_name?(name)
        upper = String(name).upcase
        CREDENTIAL_ENV_NAMES.include?(upper) || CREDENTIAL_ENV_PATTERN.match?(upper)
      end

      # Invariant 35: repository content is not authority. The executable must be
      # operator-owned — absolute, executable, not a symlink, and never inside the
      # agent workspace.

      # The allowlist names variables the child may inherit. A credential-shaped
      # name here would defeat the P8-E rule that credentials reach a child only
      # through explicit `credential_refs`, so it is rejected outright.
    end

    # The Data.define block is instance_exec'd, so the constants above live on
    # `Tamoz::Mcp`; expose Budgets under ServerConfig as the plan names it.
    ServerConfig::Budgets = Budgets
  end
end
