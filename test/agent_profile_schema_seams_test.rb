# frozen_string_literal: true

require_relative 'test_helper'

# Q2 characterization of profile.rb's schema-validation seams (the authority
# boundary: trusted-profile loading). The branches below were uncovered by the
# Q0 baseline (90.9% overall): the YAML-safety, schema, and field-validation
# failure paths. Each test is a mutation contract — removing its validation
# must fail it: bad input raises, it never silently loads.
class AgentProfileSchemaSeamsTest < Minitest::Test
  Profile = Tamoz::Agent::Profile

  def setup
    @dir = Dir.mktmpdir('tamoz-profile-seams')
    @profiles_dir = Dir.mktmpdir('tamoz-profile-seams-store')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@profiles_dir)
  end

  def valid_document(overrides = {})
    doc = {
      'profile' => {
        'schema_version' => 1,
        'profile_id' => 'test-profile',
        'profile_version' => '1.0',
        'canonical_root' => @dir
      },
      'roots' => { 'workspace' => @dir },
      'tools' => { 'allowed' => %w[read_file list_directory], 'approval_required' => [] },
      'policy' => {
        'allow_changes' => false,
        'default_check_safety' => 'read_only',
        'graph_version' => '1',
        'behavior_version' => '1.0',
        'tool_catalog_digest' => "sha256:#{'a' * 64}"
      }
    }
    overrides.each { |key, value| doc[key] = doc.fetch(key, {}).merge(value) }
    doc
  end

  def write_profile(document = valid_document, name: 'profile.yaml', mode: 0o600)
    path = File.join(@profiles_dir, name)
    File.write(path, Psych.dump(document))
    File.chmod(mode, path)
    path
  end

  def preview(document = valid_document)
    Profile.preview(write_profile(document), suggestion: true)
  end

  # --- YAML safety (scan_yaml!) ---

  def test_yaml_merge_keys_rejected
    raw = File.read(write_profile)
    raw = raw.sub("\n", "\n<<: {'sneaky' => true}\n")
    path = File.join(@profiles_dir, 'merge.yaml')
    File.write(path, raw)
    File.chmod(0o600, path)

    error = assert_raises(Profile::ValidationError) { Profile.preview(path, suggestion: true) }
    assert_match(/merge keys are not allowed/, error.message)
  end

  def test_yaml_nesting_exceeds_limit
    nested = 'deep'
    20.times { nested = "[#{nested}]" }
    raw = "profile:\n  schema_version: 1\n  value: #{nested}\n"
    path = File.join(@profiles_dir, 'nested.yaml')
    File.write(path, raw)
    File.chmod(0o600, path)

    error = assert_raises(Profile::ValidationError) { Profile.preview(path, suggestion: true) }
    assert_match(/nesting exceeds/, error.message)
  end

  # --- schema and field validation ---

  def test_profile_id_pattern_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('profile' => { 'profile_id' => 'Bad ID' }))
    end
    assert_match(/profile_id must match/, error.message)
  end

  def test_legacy_profile_id_is_reserved
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('profile' => { 'profile_id' => 'legacy' }))
    end
    assert_match(/reserved/, error.message)
  end

  def test_unknown_profile_fields_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('profile' => { 'sneaky' => 'value' }))
    end
    assert_match(/unknown profile fields/, error.message)
  end

  def test_unknown_roots_fields_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('roots' => { 'sneaky' => '/tmp' }))
    end
    assert_match(/unknown roots fields/, error.message)
  end

  def test_invalid_model_role_name_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('model_roles' => {
        'Bad Role' => { 'provider' => 'openai', 'model' => 'gpt-4o' }
      }))
    end
    assert_match(/invalid model role name/, error.message)
  end

  def test_unknown_provider_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('model_roles' => {
        'primary' => { 'provider' => 'not-a-provider', 'model' => 'gpt-4o' }
      }))
    end
    assert_match(/unknown provider/, error.message)
  end

  def test_credential_ref_kind_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('model_roles' => {
        'primary' => {
          'provider' => 'openai', 'model' => 'gpt-4o',
          'credential_ref' => { 'kind' => 'file', 'name' => 'OPENAI_API_KEY' }
        }
      }))
    end
    assert_match(/credential_ref kind must be "env"/, error.message)
  end

  def test_invalid_check_name_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('checks' => { 'Bad Check' => { 'argv' => ['ls'] } }))
    end
    assert_match(/invalid check name/, error.message)
  end

  def test_check_argv_non_string_rejected
    error = assert_raises(Profile::ValidationError) do
      preview(valid_document('checks' => { 'lint' => { 'argv' => ['ls', 42] } }))
    end
    assert_match(/argv must be a non-empty string array/, error.message)
  end
end
