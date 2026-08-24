# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/mcp/websearch"

# P17 W1 / correction 5 / correction 8: the profile `egress:` section, its
# fail-closed validation, the authority-snapshot pin, the session-record
# `egress_pin`, `verify_egress_binding!` on resume, and the one-budget
# vocabulary (egress budgets map onto ServerConfig::Budgets).
class WebsearchEgressTest < Minitest::Test
  Profile = Tamoz::Agent::Profile
  Session = Tamoz::Agent::Session

  def setup
    @base = Dir.mktmpdir("tamoz-websearch-egress")
    @workspace = File.join(@base, "workspace")
    @config_home = File.join(@base, "config")
    @sessions = File.join(@base, "sessions")
    FileUtils.mkdir_p(@workspace)
    FileUtils.mkdir_p(@sessions, mode: 0o700)
    File.write(File.join(@workspace, "note.txt"), "Tamoz is awake.\n")
  end

  def teardown
    FileUtils.remove_entry(@base)
  end

  def egress
    {
      "allowlisted_hosts" => ["api.search.example"],
      "schemes" => ["https"],
      "deny_private_ranges" => true,
      "max_request_bytes" => 2048,
      "max_response_bytes" => 65_536,
      "connect_timeout_s" => 10,
      "redirect_max_hops" => 3,
      "circuit" => {"threshold" => 3, "scope_type" => "egress", "budget_breach" => true},
      "credential_refs" => ["TAMOZ_SEARCH_API_TOKEN"]
    }
  end

  def profile_document(egress_section)
    toolbox = Tamoz::Agent::Toolbox.new(
      root: @workspace, allow_changes: false, checks: {},
      allowed_tools: %w[read_file]
    )
    document = {
      "profile" => {
        "schema_version" => 1, "profile_id" => "ws-egress-test",
        "profile_version" => "1.0", "canonical_root" => @workspace
      },
      "roots" => {"workspace" => @workspace},
      "tools" => {"allowed" => ["read_file"]},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => toolbox.catalog_digest
      }
    }
    document["egress"] = egress_section if egress_section
    document
  end

  def write_profile(document)
    directory = File.join(@config_home, "profiles")
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, @config_home)
    File.chmod(0o700, directory)
    path = File.join(directory, "ws-egress-test.yaml")
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
    path
  end

  def activate!(document)
    path = write_profile(document)
    digest = Profile.preview(path).canonical_digest
    Profile::AdoptionRegistry.new(env: {"TAMOZ_CONFIG_HOME" => @config_home})
                             .activate("ws-egress-test", digest)
    Profile.preview(path)
  end

  # --- W1: fail-closed egress validation ------------------------------------

  def test_egress_section_rejects_every_invalid_shape_typed
    invalid = [
      {"allowlisted_hosts" => ["192.168.1.1"]},
      {"allowlisted_hosts" => ["*.example.com"]},
      {"allowlisted_hosts" => ["api.example.com:8443"]},
      {"allowlisted_hosts" => ["http://api.example.com"]},
      {"allowlisted_hosts" => ["Api.Search.Example"]},
      {"allowlisted_hosts" => ["SEARCH_API_TOKEN"]},
      {"allowlisted_hosts" => []},
      {"allowlisted_hosts" => ["a", "a"]},
      {"schemes" => ["http"]},
      {"deny_private_ranges" => "yes"},
      {"max_request_bytes" => 0},
      {"max_response_bytes" => 2_000_000},
      {"connect_timeout_s" => -1},
      {"redirect_max_hops" => 0},
      {"circuit" => {"threshold" => 3, "scope_type" => "server", "budget_breach" => true}},
      {"circuit" => {"threshold" => 0, "scope_type" => "egress", "budget_breach" => true}},
      {"credential_refs" => ["SEARCH_API_TOKEN"]},
      {"credential_refs" => ["TAMOZ_A", "TAMOZ_A"]},
      {"unknown_field" => 1}
    ]
    invalid.each do |mutation|
      document = profile_document(egress.merge(mutation))
      error = assert_raises(Profile::ValidationError, "expected rejection for #{mutation.inspect}") do
        activate!(document)
      end
      assert_match(/egress/, error.message)
    end
  end

  def test_egress_section_is_optional_and_defaults_absent
    document = profile_document(nil)
    profile = activate!(document)
    assert_nil profile.egress
    refute profile.authority_snapshot.key?("egress")
  end

  # --- correction 5: authority snapshot + replay -----------------------------

  def test_egress_joins_authority_snapshot_and_replays
    profile = activate!(profile_document(egress))
    assert_equal egress, profile.egress
    assert_equal egress, profile.authority_snapshot.fetch("egress")

    replayed = Profile.from_authority(profile.authority_snapshot)
    assert_equal egress, replayed.egress
    assert_equal profile.canonical_digest, replayed.canonical_digest
  end

  def test_egress_validation_fails_closed_on_replay
    snapshot = activate!(profile_document(egress)).authority_snapshot
    tampered = Marshal.load(Marshal.dump(snapshot))
    tampered["egress"] = egress.merge("allowlisted_hosts" => ["192.168.1.1"])
    assert_raises(Profile::ValidationError) { Profile.from_authority(tampered) }
  end

  # --- verify-egress-binding (mirrors verify_skill_binding!) -----------------

  class ScriptedModel
    def initialize(plans, reviews, verification)
      @plans = plans
      @reviews = reviews
      @verification = verification
      @calls = []
    end

    attr_reader :calls

    def generate(stage:, system:, prompt:)
      @calls << stage
      queue = stage == :plan ? @plans : (stage == :review ? @reviews : @verification)
      raise "scripted model queue exhausted for #{stage}" if queue.nil? || queue.empty?

      response = stage == :verify ? queue.first : queue.shift
      JSON.generate(response)
    end
  end

  def session_with(profile)
    toolbox = Tamoz::Agent::Toolbox.new(
      root: @workspace, allow_changes: false, checks: {},
      allowed_tools: %w[read_file]
    )
    model = ScriptedModel.new(
      [read_plan],
      [{"decision" => "accept", "issues" => [], "rationale" => "sound"}],
      [{"answer" => "Tamoz is awake.", "satisfied" => true, "evidence" => ["note.txt"]}]
    )
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(@sessions, "egress.sqlite3"))
    begin
      session = Session.new(
        model:, toolbox:, checkpointer: adapter, profile:
      )
      outcome = session.start(
        "Explain note.txt.", thread: "egress-thread", request_id: "request.1"
      )
      raise "session did not complete" unless outcome.status == :completed

      [session, adapter]
    rescue StandardError
      adapter.close
      raise
    end
  end

  def read_plan
    {
      "goal" => "explain",
      "done_when" => ["read the note"],
      "steps" => [
        {
          "id" => "s1", "purpose" => "read", "tool" => "read_file",
          "arguments" => {"path" => "note.txt"}, "verification" => "output present"
        }
      ]
    }
  end

  def test_session_record_pins_the_canonical_egress_declaration
    profile = activate!(profile_document(egress))
    session, adapter = session_with(profile)
    record = session.view(thread: "egress-thread").state.fetch(:session)

    assert_equal Tamoz::Agent::Deliberation.canonical(egress), record.fetch("egress_pin")
    assert_equal egress, record.fetch("profile_authority").fetch("egress")
  ensure
    adapter&.close
  end

  def test_resume_with_changed_egress_stops_typed
    profile = activate!(profile_document(egress))
    session, adapter = session_with(profile)

    changed = egress.merge("max_request_bytes" => 4096)
    other_profile = activate!(profile_document(changed))
    toolbox = Tamoz::Agent::Toolbox.new(
      root: @workspace, allow_changes: false, checks: {},
      allowed_tools: %w[read_file]
    )
    dummy = Object.new
    def dummy.generate(**) = "{}"
    resumed = Session.new(
      model: dummy, toolbox:, checkpointer: adapter, profile: other_profile
    )
    error = assert_raises(Tamoz::Agent::EgressBindingUnavailableError) do
      resumed.verify_egress_binding!(thread: "egress-thread")
    end
    assert_match(/egress declaration/, error.message)
  ensure
    adapter&.close
  end

  def test_resume_with_identical_egress_succeeds
    profile = activate!(profile_document(egress))
    session, adapter = session_with(profile)

    toolbox = Tamoz::Agent::Toolbox.new(
      root: @workspace, allow_changes: false, checks: {},
      allowed_tools: %w[read_file]
    )
    dummy = Object.new
    def dummy.generate(**) = "{}"
    resumed = Session.new(model: dummy, toolbox:, checkpointer: adapter, profile:)
    resumed.verify_egress_binding!(thread: "egress-thread")
  ensure
    adapter&.close
  end

  def test_profileless_session_pins_no_egress_and_resumes_against_no_egress
    session, adapter = session_with(nil)
    record = session.view(thread: "egress-thread").state.fetch(:session)
    assert_equal({}, record.fetch("egress_pin"))
    # A profile-less resumed session compares {} against {} and passes.
    dummy = Object.new
    def dummy.generate(**) = "{}"
    toolbox = Tamoz::Agent::Toolbox.new(root: @workspace)
    resumed = Session.new(model: dummy, toolbox:, checkpointer: adapter)
    resumed.verify_egress_binding!(thread: "egress-thread")
  ensure
    adapter&.close
  end

  # --- correction 8: one budget vocabulary -----------------------------------

  def test_egress_budgets_map_onto_server_config_budgets
    budgets = Tamoz::Mcp::Websearch.egress_budgets(egress)
    assert_instance_of Tamoz::Mcp::ServerConfig::Budgets, budgets
    assert_equal 10.0, budgets.connect_timeout
    assert_equal 65_536, budgets.max_output_bytes
  end

  def test_egress_budget_mapping_rejects_a_malformed_declaration
    assert_raises(Tamoz::Mcp::ValidationError) do
      Tamoz::Mcp::Websearch.egress_budgets({"allowlisted_hosts" => []})
    end
  end
end
