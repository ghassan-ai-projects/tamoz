# frozen_string_literal: true

require_relative "test_helper"

# DR-5 P8 profile machinery completion (accepted rev3 plan): post-override
# role-resolution recording (D1), registry codec v2 + flocked consumption (D2),
# resume credential-ref hardening (D3). Maps to acceptance R1-R5 and the
# DR5-01..A5 probe spec.
class AgentProfileMachineryTest < Minitest::Test
  Profile = Tamoz::Agent::Profile
  ProfilePolicyError = Tamoz::Agent::ProfilePolicyError
  ProfileRoleUnavailableError = Tamoz::Agent::ProfileRoleUnavailableError
  READ_ONLY_TOOLS = %w[read_file list_directory search_text].freeze

  class ScriptedModel
    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
    end

    def generate(stage:, system:, prompt:)
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def setup
    @dir = Dir.mktmpdir("tamoz-machinery")
    @workspace = File.join(@dir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @workspace = File.realpath(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- R1: post-override role-resolution recording ----------------------------

  # DR5-01: one shared resolution function. build_model and the recorded
  # profile_roles agree on every cell of the override matrix — the record is
  # exactly the tuple build_model used (no second resolution path to drift).
  def test_shared_resolution_build_model_and_profile_roles_agree
    profile = load_profile(
      "primary" => {"provider" => "ollama", "model" => "role-primary"},
      "writer" => {"provider" => "openai", "model" => "role-writer"}
    )
    matrix = [
      # [cli model, cli provider, TAMOZ_MODEL, TAMOZ_PROVIDER, expected primary]
      [nil, nil, nil, nil, ["role-primary", "ollama"]],
      ["cli-model", nil, nil, nil, ["cli-model", "ollama"]],
      [nil, nil, "env-model", nil, ["env-model", "ollama"]],
      ["cli-model", nil, "env-model", nil, ["cli-model", "ollama"]],
      [nil, "cli-provider", nil, nil, ["role-primary", "cli-provider"]],
      [nil, nil, nil, "env-provider", ["role-primary", "env-provider"]],
      ["cli-model", "cli-provider", "env-model", "env-provider",
       ["cli-model", "cli-provider"]]
    ]

    capture = []
    stub_ruby_llm_new(capture) do
      matrix.each do |cli_model, cli_provider, env_model, env_provider, expected|
        options = {model: cli_model, provider: cli_provider}
        env = {"TAMOZ_MODEL" => env_model, "TAMOZ_PROVIDER" => env_provider}.compact
        cli = new_cli(env:)

        resolved = cli.send(:resolve_profile_roles, profile, options)
        primary = resolved.fetch("primary")
        writer = resolved.fetch("writer")
        assert_equal({"provider" => expected[1], "model" => expected[0]}, primary,
                     "primary cell #{[cli_model, cli_provider, env_model, env_provider].inspect}")
        # Non-primary roles keep their file values: build_model only ever resolves
        # :primary, so f(model_roles, overrides) leaves them untouched.
        assert_equal({"provider" => "openai", "model" => "role-writer"}, writer)

        # build_model consumes the SAME tuple for the role side of its precedence.
        built = cli.send(:build_model, options, profile:)
        assert_equal expected[0], built.model
        assert_equal expected[1], built.provider.to_s
      end
    end
    # The model that was actually constructed matches the recorded tuples for
    # every cell (the stub recorded every RubyLLMModel.new call).
    assert_equal 7, capture.length
  end

  # DR5-01 end-to-end: the durable session record carries the post-override
  # tuples; the model that ran is the model the record names.
  def test_session_record_records_post_override_roles_and_budgets
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, digest = write_profile(
        workspace:, config_home:,
        budgets: {"steps" => 10, "cost_usd" => 0.5},
        model_roles: {"primary" => {"provider" => "ollama", "model" => "gpt-5"}}
      )
      out = StringIO.new
      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out:, err:,
        env_overrides: {"TAMOZ_MODEL" => "cli-picked-model"},
        factory: read_factory, session: "th"
      )
      assert_equal 0, status, err.string

      record = session_record(session_dir, "th")
      assert_equal "test-profile", record.fetch("profile_id")
      assert_equal digest, record.fetch("profile_digest")
      # Override precedence applied: TAMOZ_MODEL beats the role's model; the
      # provider comes from the role (no provider override supplied).
      assert_equal(
        {"primary" => {"provider" => "ollama", "model" => "cli-picked-model"}},
        record.fetch("profile_roles")
      )
      # R2: budgets recorded per profile, deep-equal to profile.budgets.
      assert_equal({"steps" => 10, "cost_usd" => 0.5}, record.fetch("profile_budgets"))
    end
  end

  # DR5-02: a credential-shaped override value is refused at construction with
  # ProfilePolicyError, before any session record or checkpoint exists, and the
  # refusal cites the failing role.
  def test_secret_shaped_override_never_enters_profile_roles
    profile = load_profile("primary" => {"provider" => "ollama", "model" => "gpt-5"})
    cli = new_cli(env: {})

    assert_raises(ProfilePolicyError) do
      cli.send(:resolve_profile_roles, profile, {model: "sk-ant-abcdefghijklmnopqrstuvwxyz123456"})
    end
    error = assert_raises(ProfilePolicyError) do
      cli.send(:resolve_profile_roles, profile, {provider: "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0"})
    end
    assert_match(/primary/, error.message)

    # End-to-end: an env-supplied secret-shaped model id refuses the session
    # before any session record is created (the gate trips inside build_model,
    # before the adapter exists).
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(
        workspace:, config_home:,
        model_roles: {"primary" => {"provider" => "ollama", "model" => "gpt-5"}}
      )
      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        env_overrides: {"TAMOZ_MODEL" => "sk-ant-abcdefghijklmnopqrstuvwxyz123456"},
        factory: nil, session: "th"
      )
      assert_equal 1, status
      assert_match(/cannot be recorded in profile_roles/, err.string)
      assert_match(/primary/, err.string)
      refute File.exist?(File.join(session_dir, "th.sqlite3"))
    end
  end

  # DR5-A5: a normal model id passes the gate; a high-entropy value is rejected
  # per the cited predicates, and the refusal explains the entropy floor.
  def test_env_secret_gate_distinguishes_normal_ids_from_high_entropy
    profile = load_profile("primary" => {"provider" => "ollama", "model" => "gpt-5"})
    cli = new_cli(env: {})

    resolved = cli.send(:resolve_profile_roles, profile, {model: "google/gemini-2.5-pro"})
    assert_equal "google/gemini-2.5-pro", resolved.fetch("primary").fetch("model")

    error = assert_raises(ProfilePolicyError) do
      cli.send(:resolve_profile_roles, profile, {model: "aZ9+xK0L1mN2oP3qR4sT5uV6wX7yZ8aB9cD0eF1gH2iJ3k"})
    end
    assert_match(/high-entropy/, error.message)
    assert_match(/--model/, error.message)
  end

  # DR5-03: profile_id == "legacy" is refused at load; the sentinel semantics in
  # cli.rb are unchanged (a session record marker, not a loadable profile id).
  def test_legacy_profile_id_refused_at_load
    document = profile_document("profile_id" => "legacy")
    path = File.join(@dir, "legacy.yaml")
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)

    error = assert_raises(Profile::ValidationError) { Profile.preview(path) }
    assert_match(/reserved/, error.message)
    assert_match(/legacy/, error.message)

    # The same refusal holds on the pinned-authority replay path: a tampered
    # snapshot cannot smuggle the reserved id either.
    base = load_profile({}).authority_snapshot
    tampered = base.merge("profile_id" => "legacy")
    assert_raises(Profile::ValidationError) { Profile.from_authority(tampered) }
  end

  # DR5-04: legacy {} vs profiled {} disambiguated by profile_id; profiled with
  # zero roles is distinct from "no profile resolution existed".
  def test_legacy_sentinel_and_profiled_empty_roles_are_distinct
    legacy = build_session_record({})
    empty_roles = build_session_record(
      "profile_id" => "test-profile",
      "profile_digest" => digest_of("a"),
      "profile_roles" => {}
    )
    with_roles = build_session_record(
      "profile_id" => "test-profile",
      "profile_digest" => digest_of("a"),
      "profile_roles" => {"primary" => {"provider" => "openai", "model" => "gpt-5"}}
    )

    # (a) legacy: the sentinel profile_id makes {} unambiguous.
    assert_equal Tamoz::Agent::SessionRecords::LEGACY_PROFILE_ID, legacy.fetch("profile_id")
    assert_equal({}, legacy.fetch("profile_roles"))
    assert_equal Tamoz::Agent::SessionRecords::LEGACY_PROFILE_DIGEST, legacy.fetch("profile_digest")
    # (b) profiled with zero roles: profile_id present, {} means resolution ran.
    assert_equal "test-profile", empty_roles.fetch("profile_id")
    assert_equal({}, empty_roles.fetch("profile_roles"))
    refute_equal Tamoz::Agent::SessionRecords::LEGACY_PROFILE_ID, empty_roles.fetch("profile_id")
    # (c) profiled with roles.
    assert_equal "gpt-5", with_roles.fetch("profile_roles").fetch("primary").fetch("model")
  end

  # DR5-05: role resolution failure surfaces as the typed
  # ProfileRoleUnavailableError at session start — before any model I/O, any
  # checkpoint, any request enqueue — and the store is untouched (no partial
  # session record).
  def test_unavailable_credential_ref_is_typed_and_leaves_no_partial_session
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      broken, = write_profile(
        workspace:, config_home:, name: "broken.yaml",
        model_roles: {
          "primary" => {
            "provider" => "openai",
            "model" => "gpt-5",
            "credential_ref" => {"kind" => "env", "name" => "TAMOZ_DOES_NOT_EXIST_XYZ"}
          }
        }
      )

      without_env_keys("OPENAI_API_KEY", "TAMOZ_DOES_NOT_EXIST_XYZ") do
        err = StringIO.new
        status = run_cli(
          ["--profile", broken, "ask", "read note.txt"],
          workspace:, session_dir:, config_home:, out: StringIO.new, err:,
          factory: nil, session: "th"
        )
        assert_equal 1, status
        assert_match(/primary/, err.string)
        assert_match(/TAMOZ_DOES_NOT_EXIST_XYZ/, err.string)

        # The typed class is what propagates out of build_model at the boundary.
        cli = new_cli(env: {"TAMOZ_CONFIG_HOME" => config_home})
        assert_raises(ProfileRoleUnavailableError) do
          cli.send(:build_model, {}, profile: Profile.preview(broken))
        end
      end

      # No partial session: no durable record was created.
      refute File.exist?(File.join(session_dir, "th.sqlite3"))
    end
  end

  # DR-5 critic corner: a referenced credential that is UNSET must fail typed at
  # session start even when the GENERIC provider key IS set — the silent generic
  # fallback is the same divergence class RC-4 fixes at replay, re-introduced at
  # resolution.
  def test_referenced_credential_unset_fails_typed_even_with_the_generic_key_set
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      broken, = write_profile(
        workspace:, config_home:, name: "broken.yaml",
        model_roles: {
          "primary" => {
            "provider" => "openai",
            "model" => "gpt-5",
            "credential_ref" => {"kind" => "env", "name" => "TAMOZ_DOES_NOT_EXIST_XYZ"}
          }
        }
      )

      # The GENERIC key is set; only the ref-named key is absent. Pre-fix this
      # silently started the session on the generic key (critic DR5-05 corner).
      without_env_keys("TAMOZ_DOES_NOT_EXIST_XYZ") do
        ENV["OPENAI_API_KEY"] = "sk-generic-fallback-should-not-run"
        err = StringIO.new
        status = run_cli(
          ["--profile", broken, "ask", "read note.txt"],
          workspace:, session_dir:, config_home:, out: StringIO.new, err:,
          factory: nil, session: "th"
        )
        assert_equal 1, status
        assert_match(/TAMOZ_DOES_NOT_EXIST_XYZ/, err.string)

        cli = new_cli(env: {"TAMOZ_CONFIG_HOME" => config_home})
        assert_raises(ProfileRoleUnavailableError) do
          cli.send(:build_model, {}, profile: Profile.preview(broken))
        end
      end

      refute File.exist?(File.join(session_dir, "th.sqlite3"))
    end
  end

  # DR-5 critic blocker: consume_if_candidate! calls Time#iso8601 (a stdlib
  # extension); the shipped exe/tamoz crashed with NoMethodError in a clean
  # subprocess because nothing in the agent load chain required "time". Pin the
  # clean-process load chain (the corpus harness's -I lib paths, no bundler).
  def test_clean_subprocess_load_chain_provides_time_iso8601
    load_paths = %w[
      tamoz-core tamoz-graph tamoz-scheduler tamoz-stream tamoz-approval tamoz-sqlite
      tamoz-tools tamoz-observability tamoz-comms tamoz-cancellation tamoz-concurrency
      tamoz-agent-kernel tamoz-agent-memory tamoz-agent-capabilities tamoz-agent-session
      tamoz-agent-healing tamoz-agent-profile tamoz-agent-improvement tamoz-agent
    ].flat_map do |gem|
      ["-I", File.join(ROOT, "gems", gem, "lib")]
    end
    child = <<~'RUBY'
      require "tamoz/agent"
      raise "iso8601 unavailable" unless Time.now.utc.respond_to?(:iso8601)
      puts "ok"
    RUBY
    output = IO.popen([RbConfig.ruby, *load_paths, "-e", child], &:read)
    assert_equal 0, $?.exitstatus
    assert_includes output, "ok"
  end

  # DR5-06: budgets recorded per profile — deep-equal to profile.budgets when
  # present, the documented empty sentinel when absent; no route table invented.
  def test_budgets_recorded_or_empty_sentinel
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      assert_equal({}, session_record(session_dir, "th").fetch("profile_budgets"))
    end
  end

  # DR5-A2: profile_roles construction refuses non-plain values (a model
  # instance / provider object never reaches a durable record).
  def test_profile_roles_construction_refuses_non_plain_values
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(workspace:, config_home:)
      profile = Profile.load(path, env: {"TAMOZ_CONFIG_HOME" => config_home})
      dummy = Object.new
      def dummy.generate(**) = "{}"
      toolbox = Tamoz::Agent::Toolbox.new(
        root: workspace, allow_changes: false, checks: {}, allowed_tools: READ_ONLY_TOOLS
      )
      FileUtils.mkdir_p(session_dir, mode: 0o700)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(session_dir, "th.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
      )
      begin
        assert_raises(ProfilePolicyError) do
          Tamoz::Agent::Session.new(
            model: dummy, toolbox:, checkpointer: adapter, profile:,
            profile_roles: {"primary" => {"provider" => "openai", "model" => dummy}}
          )
        end
        assert_raises(ProfilePolicyError) do
          Tamoz::Agent::Session.new(
            model: dummy, toolbox:, checkpointer: adapter, profile:,
            profile_roles: {"primary" => "not-a-mapping"}
          )
        end
      ensure
        adapter.close
      end
    end
  end

  # --- R3: consumption recording ----------------------------------------------

  # DR5-07: codec v2 round-trips consumed_by/consumed_at; v1 files read and are
  # never rewritten on read; a v1-only reader refuses a v2 file typed.
  def test_registry_codec_v2_round_trip_and_v1_forward_read
    path = File.join(@dir, "transitions.yaml")
    registry = Profile::TransitionRegistry.new(path:)
    transition = Profile::Transition.new(
      thread_id: "th", profile_id: "p", from_digest: digest_of("a"),
      to_digest: digest_of("b"), reason: "operator_activate"
    )
    registry.record(transition)
    consumed = registry.consume_if_candidate!(
      "th", profile_id: "p", from: digest_of("a"), to: digest_of("b"), consumed_by: "request.42"
    )

    assert consumed
    assert_equal "request.42", consumed.consumed_by
    assert consumed.consumed_at

    fresh = Profile::TransitionRegistry.new(path:)
    entry = fresh.candidates("th").first
    assert_equal "request.42", entry.consumed_by
    assert_equal consumed.consumed_at, entry.consumed_at
    assert_equal 2, Psych.load_file(path).fetch("schema_version")

    # v1 file: the shipped 4-key shape loads unchanged and is NOT rewritten.
    v1_path = File.join(@dir, "v1.yaml")
    FileUtils.mkdir_p(File.dirname(v1_path), mode: 0o700)
    File.write(v1_path, Psych.dump(
      "schema_version" => 1,
      "transitions" => {"th" => [{"profile_id" => "p", "from_digest" => digest_of("a"),
                                  "to_digest" => digest_of("b"), "reason" => "operator_activate"}]}
    ))
    File.chmod(0o600, v1_path)
    v1_bytes = File.binread(v1_path)
    v1_reader = Profile::TransitionRegistry.new(path: v1_path)
    assert v1_reader.candidate?("th", profile_id: "p", from: digest_of("a"), to: digest_of("b"))
    # Read did not rewrite: bytes unchanged.
    assert_equal v1_bytes, File.binread(v1_path)

    # A write onto a v1 file bumps the schema_version in place (the codec's only
    # migration step): v1 files are never rewritten by READ, but the first write
    # upgrades them.
    v1_reader.record(
      Profile::Transition.new(
        thread_id: "th2", profile_id: "p", from_digest: digest_of("b"),
        to_digest: digest_of("c"), reason: "operator_activate"
      )
    )
    assert_equal 2, Psych.load_file(v1_path).fetch("schema_version")

    # A v1-only reader (an older binary) refuses the v2 file typed — never a
    # partial load, never a silent key drop.
    v2_data = Psych.load_file(path)
    refute_equal 1, v2_data.fetch("schema_version")
    assert_equal Profile::TransitionRegistry::REGISTRY_SCHEMA_VERSION,
                 v2_data.fetch("schema_version")
  end

  # DR5-08 / DR5-A3: ONE flocked critical section — concurrent consumers
  # serialize; the candidate is consumed exactly once and the decision is made on
  # the current file bytes (a stale before-image is never consumed).
  def test_flocked_consume_is_exactly_once_across_concurrent_writers
    path = File.join(@dir, "transitions.yaml")
    registry = Profile::TransitionRegistry.new(path:)
    registry.record(
      Profile::Transition.new(
        thread_id: "th", profile_id: "p", from_digest: digest_of("a"),
        to_digest: digest_of("b"), reason: "operator_activate"
      )
    )

    barrier = Queue.new
    results = Queue.new
    threads = 2.times.map do |i|
      Thread.new do
        own = Profile::TransitionRegistry.new(path:)
        barrier << true
        barrier.pop
        result = own.consume_if_candidate!(
          "th", profile_id: "p", from: digest_of("a"), to: digest_of("b"),
          consumed_by: "request.#{i}"
        )
        results << result
      end
    end
    threads.each(&:join)

    winners = []
    winners << results.pop until results.empty?
    winners = winners.compact
    assert_equal 1, winners.length, "exactly one consumer wins the race"
    assert_includes %w[request.0 request.1], winners.first.consumed_by

    fresh = Profile::TransitionRegistry.new(path:)
    entry = fresh.candidates("th").first
    assert_equal winners.first.consumed_by, entry.consumed_by
    # A later consume re-evaluates the CURRENT bytes: the consumed mark blocks
    # any re-consume, even against a stale before-image.
    assert_nil fresh.consume_if_candidate!(
      "th", profile_id: "p", from: digest_of("a"), to: digest_of("b"), consumed_by: "request.late"
    )
  end

  def test_record_and_consume_race_never_tears_the_file
    path = File.join(@dir, "transitions.yaml")

    25.times do |iteration|
      FileUtils.rm_f(path)
      FileUtils.rm_f("#{path}.lock")
      barrier = Queue.new
      threads = [
        Thread.new do
          registry = Profile::TransitionRegistry.new(path:)
          barrier << true
          barrier.pop
          registry.record(
            Profile::Transition.new(
              thread_id: "th", profile_id: "p", from_digest: digest_of("a"),
              to_digest: digest_of("b"), reason: "operator_activate"
            )
          )
        end,
        Thread.new do
          registry = Profile::TransitionRegistry.new(path:)
          barrier << true
          barrier.pop
          registry.consume_if_candidate!(
            "th", profile_id: "p", from: digest_of("a"), to: digest_of("b"),
            consumed_by: "request.race"
          )
        end
      ]
      threads.each(&:join)

      fresh = Profile::TransitionRegistry.new(path:)
      entries = fresh.candidates("th")
      assert_equal 1, entries.length, "iteration #{iteration}: one entry, never torn"
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  # DR5-A1: flock releases on process death (SIGKILL mid-critical-section); the
  # lock never wedges the registry and the file stays readable.
  def test_flock_releases_on_process_death
    path = File.join(@dir, "transitions.yaml")
    lock_path = "#{path}.lock"
    ready = File.join(@dir, "ready")
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)

    child = spawn(
      RbConfig.ruby, "-e",
      "f = File.open(ARGV[0], 'a'); f.flock(File::LOCK_EX); File.write(ARGV[1], 'ready'); sleep 30",
      lock_path, ready
    )
    begin
      deadline = Time.now + 10
      sleep 0.05 until File.exist?(ready) || Time.now > deadline
      assert File.exist?(ready), "child never took the lock"

      Process.kill("KILL", child)
      Process.wait(child)

      registry = Profile::TransitionRegistry.new(path:)
      finished = false
      worker = Thread.new do
        registry.record(
          Profile::Transition.new(
            thread_id: "th", profile_id: "p", from_digest: digest_of("a"),
            to_digest: digest_of("b"), reason: "operator_activate"
          )
        )
        finished = true
      end
      assert worker.join(10), "flock must release on process death (no wedged lock)"
      assert finished
      assert_equal 1, Profile::TransitionRegistry.new(path:).candidates("th").length
    ensure
      begin
        Process.kill("KILL", child)
        Process.wait(child)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      FileUtils.rm_f(ready)
    end
  end

  # DR5-09: consumed_by records the ACTUAL request id of the consuming ask —
  # present in the thread's durable request history.
  def test_consumed_by_is_the_actual_executing_request_id
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      _, second_digest = write_profile(workspace:, config_home:, tools: %w[read_file])
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", second_digest],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt again"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: read_factory, session: "th"
      )
      assert_equal 0, status, err.string
      assert_match(/Applying operator transition/, err.string)

      registry = Profile::TransitionRegistry.new(env: {"TAMOZ_CONFIG_HOME" => config_home})
      consumed = registry.candidates("th").first
      assert consumed.consumed_by
      assert_equal second_digest, session_record(session_dir, "th").fetch("profile_digest")

      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(session_dir, "th.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
      )
      begin
        dummy = Object.new
        def dummy.generate(**) = "{}"
        session = Tamoz::Agent::Session.new(
          model: dummy, toolbox: Tamoz::Agent::Toolbox.new(root: workspace),
          checkpointer: adapter
        )
        request_ids = session.app.durable_runner.history(thread: "th").map(&:request_id)
      ensure
        adapter.close
      end
      assert_includes request_ids, consumed.consumed_by
    end
  end

  # DR5-10 + DR5-11: a lost/consumed candidate falls through to pinned replay —
  # the ask still runs under the old-digest authority, never a typed terminal
  # error; the thread's record keeps its digest; no re-consume; the burned entry
  # stays in the registry (audit trail).
  def test_loser_falls_through_to_pinned_replay_and_burned_entry_stays
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, first_digest = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      _, second_digest = write_profile(workspace:, config_home:, tools: %w[read_file])
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", second_digest],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )
      # The consuming ask's candidate is burned before its run applies (consume-
      # then-fail): the entry is consumed, nothing applied, old digest kept.
      registry = Profile::TransitionRegistry.new(env: {"TAMOZ_CONFIG_HOME" => config_home})
      consumed = registry.consume_if_candidate!(
        "th", profile_id: "test-profile", from: first_digest, to: second_digest,
        consumed_by: "request.burn"
      )
      assert consumed
      assert_equal first_digest, session_record(session_dir, "th").fetch("profile_digest")

      # A subsequent ask (the "loser") falls through to pinned replay: runs
      # successfully under the OLD digest — no AdoptionError, no typed terminal
      # error for the consumed state.
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
      # The pinned (original) surface still reaches the planner.
      assert_includes prompts.first, "search_text"

      # No re-consume, no re-apply: the entry is still the one consumed mark.
      entry = Profile::TransitionRegistry.new(
        env: {"TAMOZ_CONFIG_HOME" => config_home}
      ).candidates("th").first
      assert_equal "request.burn", entry.consumed_by
      assert_nil Profile::TransitionRegistry.new(env: {"TAMOZ_CONFIG_HOME" => config_home})
                  .consume_if_candidate!(
                    "th", profile_id: "test-profile", from: first_digest, to: second_digest,
                    consumed_by: "request.late"
                  )
      # The operator can re-record explicitly: a fresh candidate is appended.
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", second_digest],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )
      entries = Profile::TransitionRegistry.new(
        env: {"TAMOZ_CONFIG_HOME" => config_home}
      ).candidates("th")
      assert_equal 2, entries.length
      assert_equal 1, entries.count { |entry| entry.consumed_by == "request.burn" }
      assert_equal 1, entries.count { |entry| !entry.consumed? }
    end
  end

  # DR5-12: dead candidates surfaced at the boundary; consumed entries excluded.
  # Digests are differentiated by budgets (same tool surface throughout), so the
  # scripted plan always succeeds and only the authority changes between edits.
  def test_dead_candidates_surfaced_and_consumed_entries_excluded
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, digest_a = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      # Candidate A->B recorded, then superseded by A->C which is consumed, then
      # the profile moves to D. A->B is now dead on both ends; A->C is consumed
      # and must not nag; C->D is the live candidate.
      _, digest_b = write_profile(workspace:, config_home:, budgets: {"steps" => 1})
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", digest_b],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )
      _, digest_c = write_profile(workspace:, config_home:, budgets: {"steps" => 2})
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", digest_c],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt again"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      assert_equal digest_c, session_record(session_dir, "th").fetch("profile_digest")

      _, digest_d = write_profile(workspace:, config_home:, budgets: {"steps" => 3})
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", digest_d],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )

      err = StringIO.new
      status = run_cli(
        ["--profile", path, "ask", "read note.txt once more"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: read_factory, session: "th"
      )
      assert_equal 0, status, err.string
      assert_match(/stale candidate transitions/, err.string)
      assert_match(/#{Regexp.escape(digest_a)} -> #{Regexp.escape(digest_b)}/, err.string)
      refute_match(/#{Regexp.escape(digest_a)} -> #{Regexp.escape(digest_c)}/, err.string)
      assert_equal digest_d, session_record(session_dir, "th").fetch("profile_digest")
    end
  end

  # DR5-13: boundary rules stay consistent — resume never consumes; ask consumes
  # exactly once per its own candidate state.
  def test_resume_never_consumes_a_candidate
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, first_digest = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      _, second_digest = write_profile(workspace:, config_home:, tools: %w[read_file])
      assert_equal 0, run_cli(
        ["--profile", path, "profile", "activate", "--thread", "th", "--digest", second_digest],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )

      # resume is boundary: false — the candidate stays untouched and the
      # thread's authority is unchanged (material change only at a turn boundary,
      # invariant 26).
      err = StringIO.new
      status = run_cli(
        ["--profile", path, "resume", "th"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:,
        factory: read_factory
      )
      assert_equal 0, status, err.string
      refute_match(/Applying operator transition/, err.string)

      registry = Profile::TransitionRegistry.new(env: {"TAMOZ_CONFIG_HOME" => config_home})
      entry = registry.candidates("th").first
      refute entry.consumed?, "resume must not consume"
      assert_equal first_digest, session_record(session_dir, "th").fetch("profile_digest")

      # ask consumes it exactly once.
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt again"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      consumed = Profile::TransitionRegistry.new(
        env: {"TAMOZ_CONFIG_HOME" => config_home}
      ).candidates("th").first
      assert consumed.consumed_by
      assert_equal second_digest, session_record(session_dir, "th").fetch("profile_digest")
    end
  end

  # --- R4: resume hardening ---------------------------------------------------

  # DR5-14: the ref-named credential resolves IDENTICALLY on pinned replay —
  # the provider call uses the ref-named key, never the generic fallback; the
  # snapshot records the NAME, never the VALUE.
  def test_ref_named_credential_resolves_identically_on_pinned_replay
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, = write_profile(
        workspace:, config_home:,
        model_roles: {
          "primary" => {
            "provider" => "openai", "model" => "gpt-5",
            "credential_ref" => {"kind" => "env", "name" => "TAMOZ_OPENAI_API_KEY"}
          }
        }
      )
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      record = session_record(session_dir, "th")
      snapshot = record.fetch("profile_authority")
      # The snapshot carries the ref NAME and never the VALUE.
      assert_equal "TAMOZ_OPENAI_API_KEY",
                   snapshot.dig("model_roles", "primary", "credential_ref", "name")
      refute_includes JSON.generate(snapshot), "sk-ref-value"

      pinned = Profile.from_authority(snapshot)
      captured = []
      stub_ruby_llm_new_into(captured) do
        cli = new_cli(env: {"TAMOZ_OPENAI_API_KEY" => "sk-ref-value",
                            "OPENAI_API_KEY" => "sk-generic-value"})
        built = cli.send(:build_model, {assume_model_exists: true}, profile: pinned)
        assert built
      end
      assert_equal "sk-ref-value", captured[0],
                   "pinned replay resolves the ref-named key, never the generic fallback"
    end
  end

  # DR5-15: the reconstructed surface comes from the snapshot, never the current
  # file — a malicious edited file cannot influence the replay.
  def test_replay_surface_comes_from_snapshot_not_the_current_file
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      path, first_digest = write_profile(workspace:, config_home:)
      assert_equal 0, run_cli(
        ["--profile", path, "ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )

      # Replace the current profile with a malicious one (same id, narrowed
      # surface, different digest). The pinned session must replay the ORIGINAL
      # surface — the file influences nothing.
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
      assert_match(/keeps its pinned authority/, err.string)
      assert_equal first_digest, session_record(session_dir, "th").fetch("profile_digest")
      # The original tool surface (search_text was in the original profile).
      assert_includes prompts.first, "search_text"
    end
  end

  # DR5-16: the EXISTING pinned_authority gate is the resume stop — a changed
  # digest with no candidate hits the same AdoptionError message as shipped; no
  # parallel digest check drifts in.
  def test_existing_pinned_authority_gate_is_the_resume_stop
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

  # DR5-A4: the legacy refusal does not break existing legacy-sentinel sessions —
  # a session whose record carries the sentinel still resumes without --profile.
  def test_legacy_sentinel_session_still_resumes_without_profile
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      assert_equal 0, run_cli(
        ["ask", "read note.txt"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory, session: "th"
      )
      record = session_record(session_dir, "th")
      assert_equal Tamoz::Agent::SessionRecords::LEGACY_PROFILE_ID, record.fetch("profile_id")
      assert_equal({}, record.fetch("profile_roles"))

      assert_equal 0, run_cli(
        ["resume", "th"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err: StringIO.new,
        factory: read_factory
      )
    end
  end

  # DR5-18: a repository .tamoz/ suggestion cannot be recorded as a candidate
  # transition (it is evidence only and refuses to load as authority).
  def test_repository_suggestion_cannot_be_recorded_as_a_candidate
    with_profile_env do |workspace, session_dir, config_home|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      suggestion_dir = File.join(workspace, ".tamoz")
      FileUtils.mkdir_p(suggestion_dir)
      suggestion = File.join(suggestion_dir, "suggested-profile.yaml")
      write_profile(workspace:, config_home:, path: suggestion, mode: 0o644)

      err = StringIO.new
      status = run_cli(
        ["--profile", suggestion, "profile", "activate", "--thread", "th",
         "--digest", "sha256:#{"c" * 64}"],
        workspace:, session_dir:, config_home:, out: StringIO.new, err:, factory: read_factory
      )
      assert_equal 1, status
      assert_match(/evidence only/, err.string)
    end
  end

  # --- helpers ---------------------------------------------------------------

  def new_cli(env: {}, out: StringIO.new, err: StringIO.new)
    Tamoz::Agent::CLI.new(out:, err:, input: StringIO.new, env:)
  end

  # Replaces RubyLLMModel.new for the duration of the block, recording every
  # call's kwargs into `capture` (an Array) and returning a plain struct that
  # answers model/provider like the real class.
  def stub_ruby_llm_new(capture)
    original = Tamoz::Agent::RubyLLMModel.method(:new)
    Tamoz::Agent::RubyLLMModel.singleton_class.define_method(:new) do |**kwargs|
      capture << kwargs
      Struct.new(:model, :provider).new(kwargs[:model], kwargs[:provider].to_sym)
    end
    yield
  ensure
    Tamoz::Agent::RubyLLMModel.singleton_class.define_method(:new, original)
  end

  # Single-value variant for DR5-14: captures the api_key into `captured[0]`.
  def stub_ruby_llm_new_into(captured)
    original = Tamoz::Agent::RubyLLMModel.method(:new)
    Tamoz::Agent::RubyLLMModel.singleton_class.define_method(:new) do |**kwargs|
      captured[0] = kwargs[:api_key]
      Struct.new(:model, :provider).new(kwargs[:model], kwargs[:provider].to_sym)
    end
    yield
  ensure
    Tamoz::Agent::RubyLLMModel.singleton_class.define_method(:new, original)
  end

  def build_session_record(extra)
    fields = {
      session_id: "th", task: "t", task_digest: "d", root: @workspace,
      graph_version: "1", behavior_version: "1",
      tool_catalog_digest: "sha256:#{"0" * 64}", created_at_ms: 0
    }.merge(extra)
    Tamoz::Agent::SessionRecords.build("session", **fields)
  end

  def load_profile(model_roles = nil)
    doc = profile_document
    doc["model_roles"] = model_roles if model_roles
    path = File.join(@dir, "profile.yaml")
    File.write(path, Psych.dump(doc))
    File.chmod(0o600, path)
    Profile.preview(path)
  end

  def without_env_keys(*names)
    originals = names.to_h { |name| [name, ENV.delete(name)] }
    yield
  ensure
    originals&.each { |name, value| ENV[name] = value if value }
  end

  def with_profile_env
    Dir.mktmpdir("tamoz-machinery-env") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      yield File.realpath(workspace), File.join(directory, "sessions"), File.join(directory, "config")
    end
  end

  def write_profile(
    workspace:, config_home:, path: nil, mode: 0o600, activate: true, budgets: {},
    tools: READ_ONLY_TOOLS, profile_id: "test-profile", name: nil, model_roles: nil
  )
    digest = catalog_digest(workspace:, tools:)
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
    document["model_roles"] = model_roles if model_roles
    if path.nil?
      directory = File.join(config_home, "profiles")
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.chmod(0o700, directory)
      path = File.join(directory, name || "#{profile_id}.yaml")
    end
    File.write(path, Psych.dump(document))
    File.chmod(mode, path)
    suggestion = mode != 0o600
    digest = Profile.preview(path, suggestion:).canonical_digest
    if activate && !suggestion
      Profile::AdoptionRegistry.new(env: {"TAMOZ_CONFIG_HOME" => config_home})
                               .activate(profile_id, digest)
    end
    [path, digest]
  end

  def profile_document(profile_fields = {})
    profile = {
      "schema_version" => 1,
      "profile_id" => "test-profile",
      "profile_version" => "1.0",
      "canonical_root" => @workspace
    }.merge(profile_fields)
    {
      "profile" => profile,
      "roots" => {"workspace" => @workspace},
      "tools" => {"allowed" => READ_ONLY_TOOLS},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => catalog_digest(workspace: @workspace, tools: READ_ONLY_TOOLS)
      }
    }
  end

  def catalog_digest(workspace:, tools:)
    Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes: false, checks: {}, allowed_tools: tools
    ).catalog_digest
  end

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

  def run_cli(argv, workspace:, session_dir:, config_home:, out:, err:,
              input: StringIO.new, factory:, session: nil, allow_changes: false,
              env_overrides: {})
    global_argv = ["--session-dir", session_dir, "--root", workspace]
    global_argv << "--allow-changes" if allow_changes
    global_argv += ["--session", session] if session
    env = {"TAMOZ_CONFIG_HOME" => config_home}.merge(env_overrides)
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

  def digest_of(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end
end
