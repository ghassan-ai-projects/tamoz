# frozen_string_literal: true

require_relative "test_helper"

# P15-B (docs/P15_RELEASE_PLAN.md §4, correction 9) — old-format resume.
#
# Invariant 22: a checkpoint written by an older build must resume EXACTLY, or
# stop typed. Every existing legacy test proves that IN PROCESS — it hands a
# Hash to `SessionRecords.load!` and checks the sentinels. None of them touch
# bytes. A schema change, a codec change or a wire-encoding change would sail
# past all of them and break every existing user's database on upgrade.
#
# `test/fixtures/legacy_session_v1.sqlite3` is a real durable session file,
# committed, whose session record has been reduced to the PRE-P8 shape: no
# profile identity, no skill epoch, no MCP catalogs, no egress pin, no memory
# epoch, no prompt-surface digest. It is regenerated only by
# `script/generate_legacy_session_fixture`, deliberately — if a format change
# makes it unreadable, the correct response is a migration or a typed refusal,
# never a fresh fixture.
class LegacySessionResumeTest < Minitest::Test
  FIXTURE = ROOT.join("test", "fixtures", "legacy_session_v1.sqlite3")
  THREAD = "legacy-thread"
  # The fields P8, P9, P10, P11 and P17 added. Their ABSENCE is what makes this
  # fixture old; each has a legacy sentinel that must still read it.
  MODERN_FIELDS = %w[
    egress_pin mcp_catalogs memory_epoch profile_budgets profile_digest
    profile_id profile_roles prompt_surface_digest skill_epoch
  ].freeze

  class SilentModel
    def generate(stage:, system:, prompt:)
      raise "the fixture thread is complete; no model call should happen"
    end
  end

  # The fixture really is old: if a regeneration accidentally captured a modern
  # record, every assertion below would be testing today's format.
  def test_the_fixture_record_is_actually_the_old_shape
    with_fixture do |session|
      record = session.view(thread: THREAD).state.fetch(:session)

      MODERN_FIELDS.each do |field|
        refute_includes record.keys, field,
                        "the fixture is not an old record: it carries #{field}"
      end
      assert_equal 1, record.fetch("record_version")
      assert_equal "tamoz.agent.session/1", record.fetch("behavior_version")
    end
  end

  # The load path: today's build reads yesterday's BYTES and reconstructs the
  # thread, sentinels and all.
  def test_a_current_build_reads_the_old_database
    with_fixture do |session|
      view = session.view(thread: THREAD)

      assert_equal :completed, view.status
      assert_equal THREAD, view.thread_id
      assert_operator view.sequence, :>, 0
      assert_equal "the note says hello", view.state.fetch(:verification).fetch("answer")
      assert view.state.fetch(:verification).fetch("satisfied")
      # The pre-P8 record loads with the legacy profile sentinels rather than
      # failing on the absent fields.
      record = Tamoz::Agent::SessionRecords.load!(view.state.fetch(:session))

      assert_equal "legacy", record.fetch("profile_id")
      assert_equal "legacy:none", record.fetch("profile_digest")
    end
  end

  # Every resume guard must accept the old thread. A guard that fired here
  # would make an upgrade unresumable — the exact failure invariant 22 forbids.
  def test_every_resume_guard_accepts_the_old_thread
    with_fixture do |session|
      session.verify_skill_binding!(thread: THREAD)
      session.verify_mcp_binding!(thread: THREAD)
      session.verify_egress_binding!(thread: THREAD)
      session.verify_behavior_binding!(thread: THREAD)
    end
  end

  # …and the guards still FAIL CLOSED for the old thread when the current
  # session is built with a capability the thread never had. "Resumes exactly
  # OR stops typed" is one rule with two halves; a fixture that only proved the
  # first half would be half a test.
  def test_an_old_thread_stops_typed_against_a_capability_it_never_had
    with_fixture do |session, workspace|
      mcp = Struct.new(:mcp_catalogs) do
        def catalogs = {"srv" => :snapshot}
        def names = []
        def read_only_names = []
        def descriptors = []
        def name?(_name) = false
        def read_only?(_name) = true
        def approval_required?(_name) = false
        def maximum_effect_output_bytes(_name) = 1024
        def validate(_name, arguments) = arguments
        def effect_intent(_name, _arguments) = {}
        def preview(_name, _arguments) = ""
        def execute(_context, _name, _arguments) = ""
      end.new({"srv" => "sha256:#{"c" * 64}"})

      with_adapter do |adapter|
        mcp_session = Tamoz::Agent::Session.new(
          model: SilentModel.new,
          toolbox: Tamoz::Tools::Toolbox.new(root: workspace),
          checkpointer: adapter,
          mcp:
        )
        error = assert_raises(Tamoz::Agent::McpCatalogSnapshotUnavailableError) do
          mcp_session.verify_mcp_binding!(thread: THREAD)
        end

        assert_includes error.message, THREAD
      end
    end
  end

  # A NEWER record version must fail before any node runs (invariant 18) —
  # the other direction of the same compatibility contract.
  def test_a_newer_record_version_is_refused_before_any_field_is_read
    error = assert_raises(Tamoz::Error) do
      Tamoz::Agent::SessionRecords.load!(
        {"record" => "session", "record_version" => 99, "session_id" => "s"}
      )
    end

    refute_empty error.message
  end

  private

  # The fixture is copied out before it is opened: a test must never mutate a
  # committed artifact, and opening a SQLite database writes to it.
  def with_fixture
    Dir.mktmpdir("tamoz-legacy-resume") do |directory|
      @workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(@workspace)
      File.write(File.join(@workspace, "note.txt"), "hello\n", encoding: Encoding::UTF_8)
      @database = File.join(directory, "legacy.sqlite3")
      FileUtils.cp(FIXTURE, @database)
      File.chmod(0o600, @database)

      with_adapter do |adapter|
        session = Tamoz::Agent::Session.new(
          model: SilentModel.new,
          toolbox: Tamoz::Tools::Toolbox.new(root: @workspace),
          checkpointer: adapter
        )
        yield session, @workspace
      end
    end
  end

  def with_adapter
    adapter = Tamoz::SQLite::Adapter.new(path: @database)
    begin
      yield adapter
    ensure
      adapter.close
    end
  end
end
