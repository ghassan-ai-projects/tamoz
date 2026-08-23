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

  class SilentModel
    def generate(stage:, system:, prompt:)
      raise "the fixture thread is complete; no model call should happen"
    end
  end

  # The fixture really is old: its checkpoints are sealed under digest rule 1
  # (pre-RFC-8785 Graph::Canonical), which is what makes every resume path stop
  # typed. A regenerated fixture that captured a modern record would carry
  # digest_version 2 and prove nothing about the refusal path.
  def test_the_fixture_checkpoint_is_sealed_under_the_pre_jcs_rule
    with_fixture do |_session|
      database = SQLite3::Database.new(@database)
      rows = database.execute(
        "SELECT digest_version, graph_version FROM tamoz_checkpoints"
      )
      refute_empty rows
      rows.each do |digest_version, graph_version|
        assert_equal 1, digest_version
        assert_equal "1", graph_version
      end
    end
  end

  # The load path: today's build reads yesterday's BYTES. The JCS digest-rule
  # cutover (PLAN_TAMOZ_STREAM_BUILD T0.1) re-sealed graph definitions, so the
  # pre-JCS fixture stops at the graph-identity guard with a typed refusal —
  # the invariant's "resumes exactly OR stops typed" second half, never a
  # silent reinterpretation of the old bytes.
  def test_a_current_build_reads_the_old_database
    with_fixture do |session|
      error = assert_raises(Tamoz::CheckpointVersionError) do
        session.view(thread: THREAD)
      end

      assert_includes error.message, "checkpoint graph identity is incompatible"
    end
  end

  # Every resume guard must stop the old thread typed. A guard that silently
  # resumed it would reinterpret digests sealed under a different rule — the
  # exact failure invariant 22 forbids. (`verify_behavior_binding!` is a no-op
  # here: the fixture session is built without memory, which returns before any
  # read.)
  def test_every_resume_guard_stops_the_old_thread_typed
    with_fixture do |session|
      %i[verify_skill_binding! verify_mcp_binding! verify_egress_binding!].each do |guard|
        assert_raises(Tamoz::CheckpointVersionError) do
          session.__send__(guard, thread: THREAD)
        end
      end
    end
  end

  # …and the guards still fail closed for the old thread when the current
  # session is built with a capability the thread never had — the graph-identity
  # refusal fires before any capability check.
  def test_an_old_thread_stops_typed_against_a_capability_it_never_had
    with_fixture do |session, workspace|
      mcp = Struct.new(:mcp_catalogs, :mcp_source_digests) do
        def catalogs = {"srv" => :snapshot}
        def names = []
        def read_only_names = []
        def descriptors = []
        def descriptor_for(_name) = nil
        def name?(_name) = false
        def read_only?(_name) = true
        def maximum_effect_output_bytes(_name) = 1024
        def validate(_name, arguments) = arguments
        def effect_intent(_name, _arguments) = {}
        def preview(_name, _arguments) = ""
        def execute(_context, _name, _arguments) = ""
      end.new({"srv" => "sha256:#{"c" * 64}"}, {"srv" => "sha256:#{"d" * 64}"})

      with_adapter do |adapter|
        mcp_session = Tamoz::Agent::Session.new(
          model: SilentModel.new,
          toolbox: Tamoz::Tools::Toolbox.new(root: workspace),
          checkpointer: adapter,
          mcp:
        )
        assert_raises(Tamoz::CheckpointVersionError) do
          mcp_session.verify_mcp_binding!(thread: THREAD)
        end
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
