# frozen_string_literal: true

# Shared by the three `tamoz code` adapters: the durable tool-calling work loop, with the same
# declared measurement artifact as the tamoz adapter (approvals auto-granted, and reported).
module Agenteval
  module TamozCode
    module_function

    def register(id:, label:, window:, guidance:)
      tamoz_root = ENV.fetch("AGENTEVAL_TAMOZ_ROOT", File.expand_path("..", Agenteval::ROOT))
      Adapters.register(
        Adapter.new(
          id:, label:, model: ENV.fetch("AGENTEVAL_MODEL", "deepseek-chat"),
          provider: ENV.fetch("AGENTEVAL_PROVIDER", "deepseek"),
          capabilities: %i[read_files edit_files create_files run_configured_check resume],
          approvals_auto_granted: true,
          env: environment(tamoz_root, window),
          stdin: "y\n" * 400,
          command: ->(scenario, dir) { argv(scenario, dir, guidance) },
          claims_success: ->(exit_code, _output) { exit_code.zero? }
        )
      )
    end

    def environment(tamoz_root, window)
      {
        "DEEPSEEK_API_KEY" => api_key(tamoz_root),
        "TAMOZ_PROVIDER" => ENV.fetch("AGENTEVAL_PROVIDER", "deepseek"),
        "TAMOZ_MODEL" => ENV.fetch("AGENTEVAL_MODEL", "deepseek-chat"),
        "TAMOZ_CONTEXT_WINDOW" => window.to_s,
        "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"),
        "BUNDLE_GEMFILE" => File.join(tamoz_root, "Gemfile"),
        "RBENV_VERSION" => File.read(File.join(tamoz_root, ".ruby-version")).strip
      }
    end

    def api_key(tamoz_root)
      key = ENV["DEEPSEEK_API_KEY"].to_s
      dotenv = File.join(tamoz_root, ".env")
      key = File.read(dotenv)[/DEEPSEEK_API_KEY\s*=\s*(\S+)/, 1].to_s if key.empty? && File.exist?(dotenv)
      key
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
