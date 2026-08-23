# frozen_string_literal: true

require_relative "test_helper"

class AgentCLIProfileTest < Minitest::Test
  Profile = Tamoz::Agent::Profile

  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  READ_ONLY_TOOLS = %w[read_file list_directory search_text].freeze

  def test_ask_with_profile_starts_a_bound_session
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, digest = write_profile(workspace:, config_home:)
      factory = read_factory
      out = StringIO.new
      err = StringIO.new

      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out:, err:, factory:, session: "th"
      )

      assert_equal 0, status, err.string
      record = session_record(session_dir, "th")
      assert_equal "test-profile", record.fetch("profile_id")
      assert_equal digest, record.fetch("profile_digest")
    end
  end

  def test_unactivated_profile_prompts_for_adoption
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(workspace:, config_home:, activate: false)
      factory = read_factory

      denied = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: denied,
        input: StringIO.new("n\n"), factory:, session: "th"
      )
      assert_equal 1, status
      assert_match(/not activated/, denied.string)

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        input: StringIO.new("y\n"), factory:, session: "th"
      )
      assert_equal 0, status, err.string
      # Adoption persists: a second run does not prompt again.
      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        input: StringIO.new, factory: read_factory, session: "th2"
      )
      assert_equal 0, status
    end
  end

  # P8-B §5.5.3: an edited profile never rebinds an existing thread by itself.
  # The thread replays the authority snapshot pinned in its own checkpoint, so
  # the narrowed tool set in the edited file is simply not applied.
  def test_changed_profile_keeps_the_pinned_authority_of_an_existing_thread
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, first_digest = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      # Operator narrows the profile; both digests are adopted.
      _, second_digest = write_profile(workspace:, config_home:, tools: %w[read_file])
      refute_equal first_digest, second_digest

      prompts = []
      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt again"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: recording_factory(prompts), session: "th"
      )

      assert_equal 0, status, err.string
      assert_match(/keeps its pinned authority #{Regexp.escape(first_digest)}/, err.string)
      assert_equal first_digest, session_record(session_dir, "th").fetch("profile_digest")
      # The pinned epoch still offers the original tool surface.
      assert_includes prompts.first, "search_text"
    end
  end

  # P8-B §5.4/§6.5: only an explicit operator-recorded candidate transition moves
  # a thread onto a new digest, and only at a turn boundary.
  def test_candidate_transition_applies_only_at_a_turn_boundary
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, first_digest = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      _, second_digest = write_profile(workspace:, config_home:, tools: %w[read_file])
      before = Digest::SHA256.file(File.join(session_dir, "th.sqlite3")).hexdigest

      out = StringIO.new
      status = run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", second_digest],
        workspace:, session_dir:, config_home:, out:, err: StringIO.new, factory: read_factory
      )
      assert_equal 0, status
      assert_match(/Candidate transition recorded for th/, out.string)
      assert_match(/next turn boundary/, out.string)
      # Recording a candidate is operator-side only: the durable session is untouched.
      assert_equal before, Digest::SHA256.file(File.join(session_dir, "th.sqlite3")).hexdigest
      assert_equal first_digest, session_record(session_dir, "th").fetch("profile_digest")

      prompts = []
      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt again"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: recording_factory(prompts), session: "th"
      )
      assert_equal 0, status, err.string
      assert_match(/Applying operator transition for th/, err.string)
      assert_equal second_digest, session_record(session_dir, "th").fetch("profile_digest")
      refute_includes prompts.first, "search_text"
    end
  end

  # P8-B §5.5.4: when the operator has revoked the grant for the digest a thread
  # was created under, the thread fails closed instead of silently adopting the
  # current file.
  def test_revoked_old_digest_fails_closed
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, first_digest = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      FileUtils.rm_f(File.join(config_home, "adoption.yaml"))
      _, second_digest = write_profile(workspace:, config_home:, tools: %w[read_file])
      refute_equal first_digest, second_digest

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt again"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: read_factory, session: "th", input: StringIO.new("y\n")
      )
      assert_equal 1, status
      assert_match(/Session was created with profile test-profile digest/, err.string)
      assert_match(/current profile digest is/, err.string)
      assert_equal first_digest, session_record(session_dir, "th").fetch("profile_digest")
    end
  end

  def test_profile_activate_rejects_foreign_threads_and_unknown_digests
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th",
         "--digest", "sha256:#{"c" * 64}"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory: read_factory
      )
      assert_equal 1, status
      assert_match(/is neither the session digest/, err.string)

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "profile", "activate", "--thread", "absent",
         "--digest", "sha256:#{"c" * 64}"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory: read_factory
      )
      assert_equal 1, status
      assert_match(/no durable session absent/, err.string)

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", "nope"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory: read_factory
      )
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_match(/sha256:/, err.string)
    end
  end

  def test_resume_legacy_session_with_profile_is_rejected
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      status = run_cli(
        ["ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      assert_equal 0, status

      path, = write_profile(workspace:, config_home:)
      err = StringIO.new
      status = run_cli(
        ["--profile", path, "resume", "th"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory: read_factory
      )
      assert_equal 1, status
      assert_match(/predates trusted profiles/, err.string)
    end
  end

  # P8-E §8.3: resume checks the profile *identity*, not just the digest — a session
  # belongs to exactly one profile family, so a second activated profile (even over
  # the same root and tool surface) cannot take its thread over.
  def test_resume_with_a_different_profile_id_is_rejected
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(workspace:, config_home:)
      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      assert_equal 0, status

      other, = write_profile(workspace:, config_home:, profile_id: "other-profile")
      err = StringIO.new
      status = run_cli(
        ["--profile", other, "resume", "th"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory: read_factory
      )
      assert_equal 1, status
      assert_match(/belongs to profile "test-profile", not "other-profile"/, err.string)
    end
  end

  def test_profile_flag_conflicts_and_unsupported_subcommands
    with_profile_env do |workspace, session_dir, config_home|
      factory = read_factory
      err = StringIO.new
      status = run_cli(
        ["--profile", "whatever", "--allow-changes", "ask", "task"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory:, allow_changes: true
      )
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_match(/do not combine/, err.string)

      err = StringIO.new
      status = run_cli(
        ["--profile", "whatever", "cancel", "th"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory:
      )
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_match(/not supported/, err.string)

      err = StringIO.new
      status = Tamoz::Agent::CLI.run(
        ["--profile", "whatever", "do", "things"],
        out: StringIO.new, err:, env: {}, model_factory: factory
      )
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_match(/not supported/, err.string)
    end
  end

  def test_suggestion_preview_and_import_flow
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      suggestion_dir = File.join(workspace, ".tamoz")
      FileUtils.mkdir_p(suggestion_dir)
      suggestion = File.join(suggestion_dir, "suggested-profile.yaml")
      write_profile(workspace:, config_home:, path: suggestion, mode: 0o644)

      out = StringIO.new
      status = run_cli(
        ["profile", "preview", suggestion],
        workspace:, session_dir:, config_home:, out:, err: StringIO.new, factory: read_factory
      )
      assert_equal 3, status
      assert_match(/profile_id: test-profile/, out.string)
      assert_match(/suggestion: true/, out.string)

      # A suggestion never becomes authority directly.
      err = StringIO.new
      status = run_cli(
        ["--profile", suggestion, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: read_factory, session: "th"
      )
      assert_equal 1, status
      assert_match(/evidence only/, err.string)

      out = StringIO.new
      status = run_cli(
        ["profile", "import", "--force", suggestion],
        workspace:, session_dir:, config_home:, out:, err: StringIO.new, factory: read_factory
      )
      assert_equal 0, status
      installed = File.join(config_home, "profiles", "test-profile.yaml")
      assert File.file?(installed)
      assert_equal 0o600, File.stat(installed).mode & 0o777

      out = StringIO.new
      status = run_cli(
        ["profile", "list"],
        workspace:, session_dir:, config_home:, out:, err: StringIO.new, factory: read_factory
      )
      assert_equal 0, status
      assert_match(/test-profile/, out.string)

      out = StringIO.new
      status = run_cli(
        ["profile", "show", "test-profile"],
        workspace:, session_dir:, config_home:, out:, err: StringIO.new, factory: read_factory
      )
      assert_equal 0, status
      assert_match(/canonical_digest: sha256:/, out.string)

      # Imported and activated: ask by id without any prompt.
      err = StringIO.new
      status = run_cli(
        ["--profile", "test-profile", "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        input: StringIO.new, factory: read_factory, session: "th"
      )
      assert_equal 0, status, err.string
      record = session_record(session_dir, "th")
      assert_equal "test-profile", record.fetch("profile_id")
    end
  end

  private

  def with_profile_env
    Dir.mktmpdir("tamoz-cli-profile") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      yield File.realpath(workspace), File.join(directory, "sessions"), File.join(directory, "config")
    end
  end

  def write_profile(
    workspace:, config_home:, path: nil, mode: 0o600, activate: true, budgets: {},
    tools: READ_ONLY_TOOLS, profile_id: "test-profile"
  )
    digest = Tamoz::Agent::Toolbox.new(
      root: workspace,
      allow_changes: false,
      checks: {},
      allowed_tools: tools
    ).catalog_digest
    document = {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => profile_id,
        "profile_version" => "1.0",
        "canonical_root" => workspace
      },
      "roots" => {"workspace" => workspace},
      "tools" => {"allowed" => tools},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => digest
      }
    }
    document["budgets"] = budgets unless budgets.empty?
    path ||= begin
      directory = File.join(config_home, "profiles")
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.chmod(0o700, directory)
      File.join(directory, "#{profile_id}.yaml")
    end
    File.write(path, Psych.dump(document))
    File.chmod(mode, path)
    suggestion = mode != 0o600
    digest = Profile.preview(path, suggestion:).canonical_digest
    if activate && !suggestion
      env = {"TAMOZ_CONFIG_HOME" => config_home}
      Profile::AdoptionRegistry.new(env:).activate(profile_id, digest)
    end
    [path, digest]
  end

  # Records the planning prompt so a test can prove which tool surface the
  # session was actually planned against.
  def recording_factory(sink)
    lambda do |options|
      model = read_factory.call(options)
      model.singleton_class.prepend(Module.new do
        define_method(:generate) do |stage:, system:, prompt:|
          sink << prompt if stage == :plan
          super(stage:, system:, prompt:)
        end
      end)
      model
    end
  end

  def read_factory
    ->(_options) do
      ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
    end
  end

  def plan_for(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {
          "id" => id,
          "purpose" => "gather evidence",
          "tool" => tool,
          "arguments" => arguments,
          "verification" => "the output is present"
        }
      ]
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "the plan is minimal and read-only"}
  end

  def run_cli(argv, workspace:, session_dir:, config_home:, out:, err:, input: StringIO.new, factory:, session: nil, allow_changes: false)
    global_argv = ["--session-dir", session_dir, "--root", workspace]
    global_argv << "--allow-changes" if allow_changes
    global_argv += ["--session", session] if session
    env = {"TAMOZ_CONFIG_HOME" => config_home}
    Tamoz::Agent::CLI.run(global_argv + argv, out:, err:, input:, env:, model_factory: factory)
  end

  def session_record(session_dir, thread_id)
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(session_dir, "#{thread_id}.sqlite3"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
    )
    begin
      dummy = Object.new
      def dummy.generate(**) = "{}"
      toolbox = Tamoz::Agent::Toolbox.new(root: Dir.tmpdir)
      session = Tamoz::Agent::Session.new(model: dummy, toolbox:, checkpointer: adapter)
      session.view(thread: thread_id).state.fetch(:session)
    ensure
      adapter.close
    end
  end
end
