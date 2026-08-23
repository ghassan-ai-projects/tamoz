# frozen_string_literal: true

require_relative "test_helper"

# P8-B: profiles bind to session/checkpoint/cache epochs. A profile edit creates a
# candidate transition and never mutates in-flight authority.
class AgentProfileTransitionTest < Minitest::Test
  Profile = Tamoz::Agent::Profile
  READ_ONLY_TOOLS = %w[read_file list_directory search_text].freeze

  def setup
    @dir = Dir.mktmpdir("tamoz-profile-transition")
    @workspace = File.join(@dir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @workspace = File.realpath(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- authority snapshot ----------------------------------------------------

  def test_authority_snapshot_carries_the_surface_and_credential_ref_name_only
    profile = load_profile(
      document(
        "model_roles" => {
          "primary" => {
            "provider" => "openai",
            "model" => "gpt-5",
            "credential_ref" => {"kind" => "env", "name" => "TAMOZ_OPENAI_API_KEY"}
          }
        }
      )
    )
    snapshot = profile.authority_snapshot

    assert profile.high_risk?
    assert_equal profile.canonical_digest, snapshot.fetch("canonical_digest")
    assert_equal READ_ONLY_TOOLS, snapshot.fetch("tools").fetch("allowed")
    # DR-5 RC4: the snapshot records the credential reference NAME so replay
    # resolves the IDENTICAL env key the original ask used; it never records a
    # credential value (invariant 24).
    assert_equal(
      {
        "provider" => "openai",
        "model" => "gpt-5",
        "credential_ref" => {"kind" => "env", "name" => "TAMOZ_OPENAI_API_KEY"}
      },
      snapshot.fetch("model_roles").fetch("primary")
    )
    assert_includes JSON.generate(snapshot), "TAMOZ_OPENAI_API_KEY"
    assert snapshot.frozen?
  end

  def test_authority_snapshot_without_refs_keeps_plain_roles
    profile = load_profile(
      document(
        "model_roles" => {"primary" => {"provider" => "openai", "model" => "gpt-5"}}
      )
    )
    snapshot = profile.authority_snapshot

    assert_equal(
      {"provider" => "openai", "model" => "gpt-5"},
      snapshot.fetch("model_roles").fetch("primary")
    )
    refute snapshot.fetch("model_roles").fetch("primary").key?("credential_ref")
  end

  def test_from_authority_reproduces_the_exact_capability_surface
    profile = load_profile(action_document)
    replayed = Profile.from_authority(profile.authority_snapshot)

    assert replayed.pinned
    refute profile.pinned
    assert_equal profile.canonical_digest, replayed.canonical_digest
    assert_equal profile.canonical_root, replayed.canonical_root
    assert_equal profile.tools_allowed, replayed.tools_allowed
    assert_equal profile.checks, replayed.checks
    assert_equal profile.policy, replayed.policy
    assert_equal toolbox_for(profile).catalog_digest, toolbox_for(replayed).catalog_digest
    assert_equal(
      profile.policy.fetch("tool_catalog_digest"),
      toolbox_for(replayed).catalog_digest
    )
  end

  # A checkpoint is storage, not authority. Replay re-runs every validator so a
  # tampered snapshot fails closed instead of widening the surface.
  def test_from_authority_rejects_tampered_snapshots
    base = load_profile(action_document).authority_snapshot

    tampered = {
      "unknown tool" => deep_merge(base, "tools" => {"allowed" => %w[read_file execute_shell]}),
      "shell metacharacter" => deep_merge(
        base, "checks" => {"answer" => {"argv" => %w[sh -c rm\ -rf\ /], "safety" => "unsafe"}}
      ),
      "unknown field" => base.merge("evil" => true),
      "relative root" => base.merge("canonical_root" => "../escape"),
      "bad digest" => base.merge("canonical_digest" => "not-a-digest"),
      "interpolated argv" => deep_merge(
        base, "checks" => {"answer" => {"argv" => ["echo", "${HOME}"], "safety" => "unsafe"}}
      ),
      "credential injection" => deep_merge(
        base,
        "model_roles" => {
          "primary" => {
            "provider" => "openai", "model" => "gpt-5",
            "credential_ref" => {"kind" => "env", "name" => "AWS_SECRET_ACCESS_KEY"}
          }
        }
      ),
      "bad safety class" => deep_merge(
        base, "checks" => {"answer" => {"argv" => %w[true], "safety" => "harmless"}}
      ),
      "not a mapping" => "profile"
    }

    tampered.each do |label, snapshot|
      error = assert_raises(Profile::ValidationError, label) { Profile.from_authority(snapshot) }
      refute_empty error.message, label
    end
  end

  def test_from_authority_root_must_still_exist_and_not_be_a_symlink
    snapshot = load_profile(document).authority_snapshot
    link = File.join(@dir, "linked-root")
    File.symlink(@workspace, link)

    assert_raises(Profile::ValidationError) do
      Profile.from_authority(snapshot.merge("canonical_root" => link))
    end
    assert_raises(Profile::ValidationError) do
      Profile.from_authority(snapshot.merge("canonical_root" => File.join(@dir, "absent")))
    end
  end

  # --- session record binding ------------------------------------------------

  def test_session_record_pins_profile_identity_and_authority
    profile = load_profile(document)
    record = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "th",
      task: "t",
      task_digest: "d",
      root: profile.canonical_root,
      graph_version: "1",
      behavior_version: "1",
      tool_catalog_digest: profile.policy.fetch("tool_catalog_digest"),
      created_at_ms: 0,
      profile_id: profile.profile_id,
      profile_digest: profile.canonical_digest,
      profile_authority: profile.authority_snapshot
    )

    assert_equal profile.canonical_digest, record.fetch("profile_digest")
    replayed = Profile.from_authority(record.fetch("profile_authority"))
    assert_equal profile.canonical_digest, replayed.canonical_digest
  end

  def test_legacy_session_record_still_loads_without_profile_fields
    record = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "th",
      task: "t",
      task_digest: "d",
      root: @workspace,
      graph_version: "1",
      behavior_version: "1",
      tool_catalog_digest: "sha256:#{"0" * 64}",
      created_at_ms: 0
    )

    assert_equal Tamoz::Agent::SessionRecords::LEGACY_PROFILE_ID, record.fetch("profile_id")
    assert_equal Tamoz::Agent::SessionRecords::LEGACY_PROFILE_DIGEST, record.fetch("profile_digest")
    refute record.key?("profile_authority")
  end

  # --- candidate transitions -------------------------------------------------

  def test_transition_registry_records_candidates_with_owner_only_permissions
    path = File.join(@dir, "config", "transitions.yaml")
    registry = Profile::TransitionRegistry.new(path:)
    transition = Profile::Transition.new(
      thread_id: "th-1",
      profile_id: "test-profile",
      from_digest: digest_of("a"),
      to_digest: digest_of("b"),
      reason: "operator_activate"
    )

    refute registry.candidate?(
      "th-1", profile_id: "test-profile", from: digest_of("a"), to: digest_of("b")
    )
    registry.record(transition)
    registry.record(transition)

    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 1, registry.candidates("th-1").length
    assert registry.candidate?(
      "th-1", profile_id: "test-profile", from: digest_of("a"), to: digest_of("b")
    )
    # A candidate is bound to one thread, one direction, and one profile family.
    refute registry.candidate?(
      "th-2", profile_id: "test-profile", from: digest_of("a"), to: digest_of("b")
    )
    refute registry.candidate?(
      "th-1", profile_id: "other-profile", from: digest_of("a"), to: digest_of("b")
    )
    refute registry.candidate?(
      "th-1", profile_id: "test-profile", from: digest_of("b"), to: digest_of("a")
    )
  end

  def test_transition_registry_rejects_malformed_input_and_documents
    path = File.join(@dir, "config", "transitions.yaml")
    registry = Profile::TransitionRegistry.new(path:)

    [
      {thread_id: "../escape", profile_id: "p", from_digest: digest_of("a"), to_digest: digest_of("b"), reason: "r"},
      {thread_id: "th", profile_id: "Bad Id", from_digest: digest_of("a"), to_digest: digest_of("b"), reason: "r"},
      {thread_id: "th", profile_id: "p", from_digest: "nope", to_digest: digest_of("b"), reason: "r"},
      {thread_id: "th", profile_id: "p", from_digest: digest_of("a"), to_digest: digest_of("b"), reason: "Bad Reason"}
    ].each do |attributes|
      assert_raises(Profile::AdoptionError) do
        registry.record(Profile::Transition.new(**attributes))
      end
    end
    refute File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, Psych.dump("schema_version" => 1, "transitions" => {"th" => [{"x" => 1}]}))
    File.chmod(0o600, path)
    assert_raises(Profile::AdoptionError) { registry.candidates("th") }
  end

  def test_transition_registry_rejects_group_readable_file
    path = File.join(@dir, "config", "transitions.yaml")
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, Psych.dump("schema_version" => 1, "transitions" => {}))
    File.chmod(0o644, path)

    assert_raises(Profile::PermissionError) do
      Profile::TransitionRegistry.new(path:).candidates("th")
    end
  end

  # --- invariant 16: stable model prefix per cache epoch ----------------------

  def test_prompt_prefix_is_stable_within_a_profile_epoch_and_changes_with_it
    profile = load_profile(document)
    other = load_profile(document, name: "second.yaml")
    narrowed = load_profile(
      document("tools" => {"allowed" => %w[read_file]}),
      name: "narrow.yaml",
      catalog_tools: %w[read_file]
    )

    assert_equal profile.canonical_digest, other.canonical_digest
    assert_equal prefix_for(profile), prefix_for(other)
    refute_equal profile.canonical_digest, narrowed.canonical_digest
    refute_equal(
      toolbox_for(profile).catalog_digest,
      toolbox_for(narrowed).catalog_digest
    )
    refute_equal prefix_for(profile), prefix_for(narrowed)
    # Replaying the pinned authority reproduces the same epoch prefix byte for byte.
    assert_equal prefix_for(profile), prefix_for(Profile.from_authority(profile.authority_snapshot))
  end

  private

  def prefix_for(profile)
    toolbox = toolbox_for(profile)
    Tamoz::Agent::Deliberation.planning_prompt(
      "task", :read_only, toolbox.names, [], [], {}, toolbox:
    )
  end

  def toolbox_for(profile)
    Tamoz::Agent::Toolbox.new(
      root: profile.canonical_root,
      allow_changes: profile.allow_changes?,
      checks: profile.checks.transform_values { |check| check.fetch("argv") },
      check_safeties: profile.checks.transform_values { |check| check.fetch("safety").to_sym },
      allowed_tools: profile.tools_allowed
    )
  end

  def digest_of(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end

  def deep_merge(base, overrides)
    overrides.each_with_object(base.dup) do |(key, value), merged|
      merged[key] = value
    end
  end

  def catalog_digest(allowed_tools:, allow_changes: false, checks: {}, check_safeties: {})
    Tamoz::Agent::Toolbox.new(
      root: @workspace,
      allow_changes:,
      checks:,
      check_safeties:,
      allowed_tools:
    ).catalog_digest
  end

  def document(overrides = {})
    base = {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "test-profile",
        "profile_version" => "1.0",
        "canonical_root" => @workspace
      },
      "roots" => {"workspace" => @workspace},
      "tools" => {"allowed" => READ_ONLY_TOOLS},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => catalog_digest(allowed_tools: READ_ONLY_TOOLS)
      }
    }
    overrides.each { |key, value| base[key] = value }
    base
  end

  def action_document
    checks = {"answer" => {"argv" => [RbConfig.ruby, "-e", "exit 0"], "safety" => "unsafe"}}
    allowed = %w[read_file list_directory apply_patch create_file run_check]
    document(
      "checks" => checks,
      "tools" => {"allowed" => allowed},
      "model_roles" => {"primary" => {"provider" => "openai", "model" => "gpt-5"}},
      "policy" => {
        "allow_changes" => true,
        "default_check_safety" => "unsafe",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => catalog_digest(
          allowed_tools: allowed,
          allow_changes: true,
          checks: {"answer" => [RbConfig.ruby, "-e", "exit 0"]},
          check_safeties: {"answer" => :unsafe}
        )
      }
    )
  end

  def load_profile(doc, name: "profile.yaml", catalog_tools: nil)
    _ = catalog_tools
    path = File.join(@dir, name)
    File.write(path, Psych.dump(doc))
    File.chmod(0o600, path)
    Profile.preview(path)
  end
end
