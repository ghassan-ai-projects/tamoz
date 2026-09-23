# frozen_string_literal: true

# Tamoz adapter. Everything agent-specific lives here; the framework itself knows none of it.
#
# Approval handling is a declared measurement artifact: Tamoz asks before every effect, and
# an unattended run answers "y". That measures Tamoz with its central safety property
# disabled, so the report labels it and the approval count is reported rather than hidden.

module Agenteval
  tamoz_root = ENV.fetch("AGENTEVAL_TAMOZ_ROOT", File.expand_path("..", Agenteval::ROOT))

  api_key = ENV["DEEPSEEK_API_KEY"].to_s
  if api_key.empty?
    dotenv = File.join(tamoz_root, ".env")
    if File.exist?(dotenv)
      api_key = File.read(dotenv)[/DEEPSEEK_API_KEY\s*=\s*(\S+)/, 1].to_s
    end
  end

  Adapters.register(
    Adapter.new(
      id: "tamoz",
      label: "Tamoz Agent",
      model: ENV.fetch("AGENTEVAL_MODEL", "deepseek/deepseek-v4.1-flash"),
      provider: ENV.fetch("AGENTEVAL_PROVIDER", "openrouter"),
      capabilities: %i[read_files edit_files create_files run_configured_check resume],
      approvals_auto_granted: true,
      env: {
        "DEEPSEEK_API_KEY" => api_key,
        "TAMOZ_PROVIDER" => ENV.fetch("AGENTEVAL_PROVIDER", "openrouter"),
        "TAMOZ_MODEL" => ENV.fetch("AGENTEVAL_MODEL", "deepseek/deepseek-v4.1-flash"),
        "PATH" => ENV.fetch("PATH"),
        "HOME" => ENV.fetch("HOME"),
        # The agent runs with the workspace as its working directory, which is a temp dir
        # with no Gemfile and no .ruby-version — both have to be pinned explicitly.
        "BUNDLE_GEMFILE" => File.join(tamoz_root, "Gemfile"),
        "RBENV_VERSION" => File.read(File.join(tamoz_root, ".ruby-version")).strip
      },
      # Approvals are read from stdin; a generous supply of "y" keeps an unattended run
      # moving without special-casing any prompt.
      stdin: "y\n" * 200,
      command: lambda do |scenario, dir|
        # The session store must not be the operator's live one. Without this the eval
        # writes a durable thread per trial into ~/Library/Application Support/tamoz/
        # sessions and never cleans it up, so a paid run leaves hundreds of threads
        # behind and its state can leak between trials.
        session_dir = File.join(ENV.fetch("AGENTEVAL_SESSION_DIR", Agenteval::ROOT), "sessions")
        FileUtils.mkdir_p(session_dir, mode: 0o700)
        argv = ["rbenv", "exec", "bundle", "exec", "tamoz",
                "--root", dir, "--session-dir", session_dir]
        unless scenario.readonly
          argv += ["--allow-changes", "--check", "test=#{scenario.notes.fetch("check_command")}"]
        end
        argv + [scenario.prompt]
      end,
      # Tamoz exits 0 only when its own verification says the task was satisfied, so the
      # exit code is a truthful claim signal for this agent.
      claims_success: ->(exit_code, _output) { exit_code.zero? }
    )
  )
end
