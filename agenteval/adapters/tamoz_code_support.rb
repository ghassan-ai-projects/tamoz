# frozen_string_literal: true

# Shared by the `tamoz code` adapters: the durable tool-calling work loop, with the same declared
# measurement artifact as the tamoz adapter (approvals auto-granted, and reported).
module Agenteval
  module TamozCode
    module_function

    # The eval's real-model route while the DeepSeek direct account has no balance. Cross-checked
    # against the pinned data by test/model_windows_test.rb: https://openrouter.ai/api/v1/models
    # listed deepseek/deepseek-v4.1-flash at context_window 1048576 on 2026-09-23, and it carries
    # input_cache_read pricing, so the cache-hit predictions are measurable on this route.
    DEFAULT_PROVIDER = "openrouter"
    DEFAULT_MODEL = "deepseek/deepseek-v4.1-flash"
    DEFAULT_WINDOW = 1_048_576

    def register(id:, label:, window: nil, guidance:)
      window ||= ENV.fetch("AGENTEVAL_CONTEXT_WINDOW", DEFAULT_WINDOW).to_i
      tamoz_root = ENV.fetch("AGENTEVAL_TAMOZ_ROOT", File.expand_path("..", Agenteval::ROOT))
      Adapters.register(
        Adapter.new(
          id:, label:, model: provider_model, provider: provider,
          capabilities: %i[read_files edit_files create_files run_configured_check resume],
          approvals_auto_granted: true,
          env: environment(tamoz_root, window),
          stdin: "y\n" * 400,
          command: ->(scenario, dir) { argv(scenario, dir, guidance) },
          claims_success: ->(exit_code, _output) { exit_code.zero? }
        )
      )
    end

    def provider = ENV.fetch("AGENTEVAL_PROVIDER", DEFAULT_PROVIDER)

    def provider_model = ENV.fetch("AGENTEVAL_MODEL", DEFAULT_MODEL)

    def environment(tamoz_root, window)
      {
        # Both credentials travel: the run's provider decides which one the route needs.
        "DEEPSEEK_API_KEY" => credential(tamoz_root, "DEEPSEEK_API_KEY"),
        "OPENROUTER_API_KEY" => credential(tamoz_root, "OPENROUTER_API_KEY"),
        "TAMOZ_PROVIDER" => provider,
        "TAMOZ_MODEL" => provider_model,
        "TAMOZ_CONTEXT_WINDOW" => window.to_s,
        "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"),
        "BUNDLE_GEMFILE" => File.join(tamoz_root, "Gemfile"),
        "RBENV_VERSION" => File.read(File.join(tamoz_root, ".ruby-version")).strip
      }.compact
    end

    def credential(tamoz_root, name)
      value = ENV[name].to_s
      return value unless value.empty?

      dotenv = File.join(tamoz_root, ".env")
      return nil unless File.exist?(dotenv)

      key = File.read(dotenv)[/#{name}\s*=\s*(\S+)/, 1].to_s
      key.empty? ? nil : key
    end

    def argv(scenario, dir, guidance)
      session_dir = File.expand_path(File.join(ENV.fetch("AGENTEVAL_SESSION_DIR", Agenteval::ROOT), "sessions"))
      FileUtils.mkdir_p(session_dir, mode: 0o700)
      argv = ["rbenv", "exec", "bundle", "exec", "tamoz", "--root", dir, "--session-dir", session_dir,
              "--allow-changes", "--check", "test=#{scenario.notes.fetch('check_command')}"]
      argv += ["--guidance", "AGENTS.md"] if guidance
      argv + ["code", scenario.prompt]
    end
  end
end
