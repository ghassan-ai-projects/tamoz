# frozen_string_literal: true

require_relative 'test_helper'

# Q2 characterization of profile.rb's ADOPTION-registry seams (giant #2, slice 2).
#
# The adoption registry is the only record of which profile digests the operator
# has actually trusted: `Profile.load` refuses a profile whose digest is not
# activated here. So every way of READING it must fail closed — a registry that
# is corrupt, foreign-versioned, tampered, or group-readable must raise, and a
# non-digest token must never be honoured as an activation.
#
# The transition registry already has these tests
# (agent_profile_transition_test.rb); the adoption registry had none — before
# this file, no test in the suite asserted either of its two error messages
# ("adoption registry is invalid" / "... is unreadable"). Each test is a
# mutation contract: deleting the validation it names must fail it.
class AgentProfileAdoptionSeamsTest < Minitest::Test
  Profile = Tamoz::Agent::Profile

  DIGEST = "sha256:#{'a' * 64}".freeze
  OTHER_DIGEST = "sha256:#{'b' * 64}".freeze

  def setup
    @dir = Dir.mktmpdir('tamoz-adoption-seams')
    @path = File.join(@dir, 'config', 'adoption.yaml')
    FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- the codec fails closed ------------------------------------------------

  # A registry written by a future (or foreign) Tamoz must not be read with
  # today's meaning. Dropping the version check would honour its entries.
  def test_a_foreign_schema_version_is_refused_not_honoured
    write_registry({ 'schema_version' => 2, 'activated' => { 'p' => [DIGEST] } })

    assert_invalid_registry
  end

  # The tampering case this seam exists for: a token that is not a digest must
  # never stand in for one.
  def test_a_non_digest_activation_entry_is_refused
    write_registry({ 'schema_version' => 1, 'activated' => { 'p' => ['yes'] } })

    assert_invalid_registry
  end

  def test_a_digest_of_the_wrong_shape_is_refused
    write_registry({ 'schema_version' => 1, 'activated' => { 'p' => ["sha256:#{'a' * 63}"] } })

    assert_invalid_registry
  end

  def test_a_registry_that_is_not_a_mapping_is_refused
    write_registry(%w[schema_version activated])

    assert_invalid_registry
  end

  def test_a_non_mapping_activated_section_is_refused
    write_registry({ 'schema_version' => 1, 'activated' => ['p'] })

    assert_invalid_registry
  end

  def test_a_non_array_digest_list_is_refused
    write_registry({ 'schema_version' => 1, 'activated' => { 'p' => DIGEST } })

    assert_invalid_registry
  end

  def test_a_non_string_profile_id_key_is_refused
    write_registry({ 'schema_version' => 1, 'activated' => { 1 => [DIGEST] } })

    assert_invalid_registry
  end

  # --- unreadable bytes are typed, never silent ------------------------------

  def test_unparseable_yaml_is_typed_as_unreadable
    write_raw("activated: [\n")

    error = assert_raises(Profile::AdoptionError) { registry.activated?('p', DIGEST) }
    assert_match(/adoption registry is unreadable/, error.message)
  end

  # safe_load runs with aliases disabled, so an alias-expanded registry cannot
  # smuggle one profile's activations onto another id.
  def test_yaml_aliases_are_refused
    write_raw("schema_version: 1\nactivated:\n  p: &a\n    - #{DIGEST}\n  q: *a\n")

    error = assert_raises(Profile::AdoptionError) { registry.activated?('q', DIGEST) }
    assert_match(/adoption registry is unreadable/, error.message)
  end

  # --- owner-only storage ----------------------------------------------------

  def test_a_group_readable_registry_is_refused
    write_registry({ 'schema_version' => 1, 'activated' => {} }, mode: 0o644)

    assert_raises(Profile::PermissionError) { registry.activated?('p', DIGEST) }
  end

  # activate verifies permissions BEFORE it reads or writes, so a registry an
  # attacker can read is never extended in place.
  def test_activate_refuses_to_write_through_a_group_readable_registry
    write_registry({ 'schema_version' => 1, 'activated' => {} }, mode: 0o644)
    before = File.read(@path)

    assert_raises(Profile::PermissionError) { registry.activate('p', DIGEST) }
    assert_equal before, File.read(@path)
  end

  # --- activate's write contract ---------------------------------------------

  def test_activate_creates_an_owner_only_registry
    registry.activate('p', DIGEST)

    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@path)).mode & 0o777
    assert registry.activated?('p', DIGEST)
  end

  def test_activate_is_idempotent_and_preserves_other_profiles
    registry.activate('p', DIGEST)
    registry.activate('q', OTHER_DIGEST)
    registry.activate('p', DIGEST)

    assert_equal [DIGEST], registry.digests('p')
    assert_equal [OTHER_DIGEST], registry.digests('q')
  end

  # Adoption is per DIGEST, not per profile id: a new digest for an already
  # adopted profile is an additional activation, never a replacement.
  def test_a_second_digest_for_the_same_profile_is_appended
    registry.activate('p', DIGEST)
    registry.activate('p', OTHER_DIGEST)

    assert_equal [DIGEST, OTHER_DIGEST], registry.digests('p')
    assert registry.activated?('p', DIGEST)
    assert registry.activated?('p', OTHER_DIGEST)
  end

  def test_an_absent_registry_adopts_nothing
    refute_path_exists @path
    refute registry.activated?('p', DIGEST)
    assert_empty registry.digests('p')
  end

  private

  def registry
    Profile::AdoptionRegistry.new(path: @path)
  end

  def write_registry(document, mode: 0o600)
    File.write(@path, Psych.dump(document))
    File.chmod(mode, @path)
    @path
  end

  def write_raw(text, mode: 0o600)
    File.write(@path, text)
    File.chmod(mode, @path)
    @path
  end

  def assert_invalid_registry
    error = assert_raises(Profile::AdoptionError) { registry.activated?('p', DIGEST) }
    assert_match(/adoption registry is invalid/, error.message)
  end
end
