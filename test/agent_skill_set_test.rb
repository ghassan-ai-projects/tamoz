# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"

# P5/§B6-B9: the skill set — wire-carried refs resolved only from the
# operator-approved source with tree-digest verification; the canonical
# skill-set digest is replay-stable. Fixture data throughout.
class AgentSkillSetTest < Minitest::Test
  SkillSet = Tamoz::Agent::SkillSet

  def source
    {
      "pond_oxygen" => "Operate the aerator when dissolved oxygen falls below 4 mg/L.",
      "shade" => "Deploy shade cloth when temperature exceeds 32°C."
    }
  end

  def refs_json(source = self.source)
    Tamoz::Core.jcs(source.map do |name, text|
      {"name" => name, "tree_sha256" => "sha256:#{Digest::SHA256.hexdigest(text)}"}
    end)
  end

  def test_verify_wire_resolves_and_pins_the_refs
    set = SkillSet.verify_wire(refs_json, source:)

    assert_equal %w[pond_oxygen shade], set.refs.map(&:name)
    refute_nil set.digest
  end

  def test_an_empty_skill_set_is_valid
    set = SkillSet.verify_wire("", source:)
    assert set.empty?
    # The empty set's digest is deterministic.
    assert_equal SkillSet.verify_wire("", source:).digest, set.digest
  end

  def test_an_unknown_skill_ref_fails_closed
    unknown = Tamoz::Core.jcs(
      [{"name" => "launch_missiles", "tree_sha256" => "sha256:#{"f" * 64}"}]
    )
    assert_raises(Tamoz::Agent::SkillSetError) do
      SkillSet.verify_wire(unknown, source:)
    end
  end

  def test_a_tree_digest_mismatch_fails_closed
    forged = Tamoz::Core.jcs(
      [{"name" => "pond_oxygen", "tree_sha256" => "sha256:#{"e" * 64}"}]
    )
    assert_raises(Tamoz::Agent::SkillSetError) do
      SkillSet.verify_wire(forged, source:)
    end
  end

  def test_a_duplicate_name_fails_closed
    parsed = Tamoz::Core.parse_json_strict(refs_json)
    duplicate = Tamoz::Core.jcs(parsed + [{
      "name" => "pond_oxygen", "tree_sha256" => "sha256:#{Digest::SHA256.hexdigest(source["pond_oxygen"])}"
    }])
    assert_raises(Tamoz::Agent::SkillSetError) do
      SkillSet.verify_wire(duplicate, source:)
    end
  end

  def test_order_binds_the_digest
    reversed = Tamoz::Core.jcs(Tamoz::Core.parse_json_strict(refs_json).reverse)
    refute_equal SkillSet.verify_wire(refs_json, source:).digest,
                 SkillSet.verify_wire(reversed, source:).digest
  end
end
