# frozen_string_literal: true

require_relative "test_helper"

class AgentProfileTest < Minitest::Test
  Profile = Tamoz::Agent::Profile
  DIGEST = "sha256:#{"a" * 64}"

  def setup
    @dir = Dir.mktmpdir("tamoz-profile")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def valid_document(overrides = {})
    doc = {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "test-profile",
        "profile_version" => "1.0",
        "canonical_root" => @dir
      },
      "roots" => {"workspace" => @dir},
      "tools" => {"allowed" => %w[read_file list_directory], "approval_required" => []},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => DIGEST
      }
    }
    overrides.each do |key, value|
      doc[key] = doc.fetch(key, {}).merge(value)
    end
    doc
  end

  def write_profile(document = valid_document, name: "profile.yaml", mode: 0o600, dir: @dir)
    path = File.join(dir, name)
    File.write(path, Psych.dump(document))
    File.chmod(mode, path)
    path
  end

  def preview(document = valid_document)
    Profile.preview(write_profile(document), suggestion: true)
  end

  def test_valid_profile_loads
    profile = Profile.preview(write_profile)
    assert_equal "test-profile", profile.profile_id
    assert_equal "1.0", profile.profile_version
    assert_equal File.realpath(@dir), profile.canonical_root
    assert_equal %w[read_file list_directory], profile.tools_allowed
    refute profile.allow_changes?
    refute profile.suggestion
    assert_match(/\Asha256:[0-9a-f]{64}\z/, profile.canonical_digest)
    assert profile.fields.frozen?
    assert profile.model_roles.frozen?
    assert profile.policy.frozen?
  end

  def test_unknown_schema_version_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document("profile" => {"schema_version" => 99}))
    end
    assert_match(/schema version/i, error.message)
  end

  def test_duplicate_keys_rejected
    path = write_profile
    text = File.read(path).sub("roots:", "roots:\n  extra: 1\nroots:")
    File.write(path, text)
    assert_raises(Profile::ValidationError) { Profile.preview(path, suggestion: true) }
  end

  def test_alias_count_limit
    text = <<~YAML
      profile:
        schema_version: 1
        profile_id: test-profile
        profile_version: "1.0"
        canonical_root: #{@dir}
      roots:
        workspace: #{@dir}
      tools:
        allowed: [read_file]
      policy:
        allow_changes: false
        default_check_safety: read_only
        graph_version: "1"
        behavior_version: "1.0"
        tool_catalog_digest: #{DIGEST}
      model_roles:
        primary:
          provider: openai
          model: gpt-5
      budgets:
        steps: &step 5
      checks:
        c1:
          argv: [*step, *step, *step, *step, *step, *step, *step, *step]
          safety: read_only
        c2:
          argv: [*step, *step, *step, *step, *step, *step, *step, *step]
          safety: read_only
        c3:
          argv: [*step, *step, *step, *step, *step, *step, *step, *step]
          safety: read_only
        c4:
          argv: [*step, *step, *step, *step, *step, *step, *step, *step, *step]
          safety: read_only
    YAML
    path = File.join(@dir, "aliased.yaml")
    File.write(path, text)
    File.chmod(0o600, path)
    error = assert_raises(Profile::ValidationError) { Profile.preview(path, suggestion: true) }
    assert_match(/alias/i, error.message)
  end

  def test_ruby_tag_rejected
    path = write_profile
    text = File.read(path).sub(
      "behavior_version: '1.0'",
      "behavior_version: !ruby/object:Object {}"
    )
    text = File.read(path).sub(
      "behavior_version: 1.0",
      "behavior_version: !ruby/object:Object {}"
    ) unless text.include?("!ruby")
    File.write(path, text)
    error = assert_raises(Profile::ValidationError) { Profile.preview(path, suggestion: true) }
    assert_match(/tags are not allowed/, error.message)
  end

  def test_interpolation_rejected
    document = valid_document("checks" => {})
    document["checks"] = {"c1" => {"argv" => ["echo", "${HOME}"], "safety" => "read_only"}}
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/interpolation/, error.message)
  end

  def test_embedded_api_key_rejected
    document = valid_document("model_roles" => {})
    document["model_roles"] = {
      "primary" => {"provider" => "openai", "model" => "gpt-5", "api_key" => "sk-abc123def456"}
    }
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/api_key/, error.message)
  end

  def test_secret_value_heuristic
    document = valid_document("profile" => {
      "description" => "token A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0"
    })
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/secret/i, error.message)
  end

  def test_relative_root_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document("profile" => {"canonical_root" => "./project"}))
    end
    assert_match(/absolute path/, error.message)
  end

  def test_symlink_root_rejected
    target = Dir.mktmpdir("tamoz-target")
    link = File.join(@dir, "linked-root")
    File.symlink(target, link)
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document(
        "profile" => {"canonical_root" => link}, "roots" => {"workspace" => link}
      ))
    end
    assert_match(/symlink/, error.message)
  ensure
    FileUtils.remove_entry(target) if target
  end

  def test_unknown_field_rejected
    document = valid_document
    document["telemetry"] = {"enabled" => true}
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/unknown sections/, error.message)
  end

  def test_shell_metacharacter_in_argv
    document = valid_document("checks" => {})
    document["checks"] = {"c1" => {"argv" => ["sh", "-c", "echo ok; rm -rf x"], "safety" => "unsafe"}}
    document["tools"] = {"allowed" => %w[read_file run_check], "approval_required" => ["run_check"]}
    document["policy"] = valid_document.fetch("policy").merge("allow_changes" => true)
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/metacharacters/, error.message)
  end

  def test_implicit_host_root_rejected
    assert_raises(Profile::ValidationError) do
      preview(valid_document("profile" => {"canonical_root" => "local"}))
    end
  end

  def test_bad_permission_rejected
    path = write_profile(valid_document, mode: 0o644)
    assert_raises(Profile::PermissionError) { Profile.preview(path) }

    path = write_profile(valid_document, name: "group.yaml", mode: 0o660)
    assert_raises(Profile::PermissionError) { Profile.preview(path) }

    group_dir = File.join(@dir, "group-dir")
    FileUtils.mkdir_p(group_dir)
    File.chmod(0o770, group_dir)
    path = write_profile(valid_document, name: "inner.yaml", dir: group_dir)
    assert_raises(Profile::PermissionError) { Profile.preview(path) }
  end

  def test_profile_file_symlink_rejected
    path = write_profile
    link = File.join(@dir, "linked.yaml")
    File.symlink(path, link)
    assert_raises(Profile::PermissionError) { Profile.preview(link) }
  end

  def test_suggestion_directory_never_activates
    suggestion_dir = File.join(@dir, ".tamoz")
    FileUtils.mkdir_p(suggestion_dir)
    File.chmod(0o700, suggestion_dir)
    path = write_profile(valid_document, name: Profile::SUGGESTION_BASENAME, dir: suggestion_dir)
    assert_raises(Profile::ValidationError) { Profile.preview(path) }
    evidence = Profile.preview(path, suggestion: true)
    assert evidence.suggestion
  end

  def test_canonical_digest_stable
    first = preview
    reordered = {
      "roots" => {"workspace" => @dir},
      "profile" => {
        "canonical_root" => @dir,
        "profile_version" => "1.0",
        "profile_id" => "test-profile",
        "schema_version" => 1
      },
      "policy" => valid_document.fetch("policy"),
      "tools" => {"approval_required" => [], "allowed" => %w[read_file list_directory]}
    }
    second = preview(reordered)
    assert_equal first.canonical_digest, second.canonical_digest
  end

  def test_canonical_digest_distinguishes
    first = preview
    second = preview(valid_document("budgets" => {"steps" => 10}))
    refute_equal first.canonical_digest, second.canonical_digest
  end

  def test_adoption_not_in_digest
    plain = preview
    decorated = valid_document
    decorated["adoption"] = {"activated_at" => "2026-08-01", "operator" => "test"}
    assert_equal plain.canonical_digest, preview(decorated).canonical_digest
  end

  def test_api_base_rejected
    document = valid_document("model_roles" => {})
    document["model_roles"] = {
      "primary" => {"provider" => "openai", "model" => "gpt-5", "api_base" => "http://x"}
    }
    assert_raises(Profile::ValidationError) { preview(document) }
  end

  def test_generic_credential_ref_rejected
    document = valid_document("model_roles" => {})
    document["model_roles"] = {
      "primary" => {
        "provider" => "openai",
        "model" => "gpt-5",
        "credential_ref" => {"kind" => "env", "name" => "OPENAI_API_KEY"}
      }
    }
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/credential_ref name/, error.message)
  end

  def test_tamoz_credential_ref_allowed
    document = valid_document("model_roles" => {})
    document["model_roles"] = {
      "primary" => {
        "provider" => "openai",
        "model" => "gpt-5",
        "credential_ref" => {"kind" => "env", "name" => "TAMOZ_OPENAI_API_KEY"}
      }
    }
    profile = preview(document)
    assert profile.high_risk?
    assert_equal "TAMOZ_OPENAI_API_KEY",
                 profile.model_roles.fetch("primary").fetch("credential_ref").fetch("name")
  end

  def test_workspace_must_equal_canonical_root
    other = Dir.mktmpdir("tamoz-other")
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document("roots" => {"workspace" => other}))
    end
    assert_match(/must equal/, error.message)
  ensure
    FileUtils.remove_entry(other) if other
  end

  def test_allow_changes_false_rejects_action_tools
    document = valid_document("tools" => {})
    document["tools"] = {"allowed" => %w[read_file apply_patch], "approval_required" => ["apply_patch"]}
    error = assert_raises(Profile::ValidationError) { preview(document) }
    assert_match(/allow_changes is false/, error.message)
  end

  def test_load_requires_adoption
    path = write_profile
    registry = Profile::AdoptionRegistry.new(path: File.join(@dir, "adoption.yaml"))
    error = assert_raises(Profile::AdoptionError) do
      Profile.load(path, adoption_registry: registry)
    end
    assert_match(/not activated/, error.message)
  end

  def test_load_activates_after_confirmation_and_skips_prompt_next_time
    path = write_profile
    registry = Profile::AdoptionRegistry.new(path: File.join(@dir, "adoption.yaml"))
    prompted = 0
    confirm = ->(_document) { prompted += 1; true }

    first = Profile.load(path, adoption_registry: registry, confirm_adoption: confirm)
    assert_equal 1, prompted
    second = Profile.load(path, adoption_registry: registry, confirm_adoption: confirm)
    assert_equal 1, prompted
    assert_equal first.canonical_digest, second.canonical_digest
    assert_equal 0o600, File.stat(File.join(@dir, "adoption.yaml")).mode & 0o777
  end

  def test_load_reprompts_when_profile_changes
    registry = Profile::AdoptionRegistry.new(path: File.join(@dir, "adoption.yaml"))
    confirm = ->(_document) { true }
    Profile.load(write_profile, adoption_registry: registry, confirm_adoption: confirm)
    changed = write_profile(valid_document("budgets" => {"steps" => 3}), name: "changed.yaml")
    assert_raises(Profile::AdoptionError) do
      Profile.load(changed, adoption_registry: registry)
    end
  end

  def test_resolve_path_precedence
    env = {
      "TAMOZ_PROFILE" => "/tmp/env-profile.yaml",
      "TAMOZ_PROFILE_ID" => "env-id",
      "XDG_CONFIG_HOME" => "/tmp/xdg"
    }
    assert_equal "/tmp/flag.yaml",
                 Profile.resolve_path(profile: "/tmp/flag.yaml", env:)
    assert_equal "/tmp/env-profile.yaml", Profile.resolve_path(env:)
    assert_equal File.join(Profile.profiles_dir(env:), "env-id.yaml"),
                 Profile.resolve_path(env: env.reject { |key, _| key == "TAMOZ_PROFILE" })
    assert_nil Profile.resolve_path(env: {})
    assert_equal File.join(Profile.profiles_dir(env:), "my-profile.yaml"),
                 Profile.resolve_path(profile: "my-profile", env:)
  end
end
