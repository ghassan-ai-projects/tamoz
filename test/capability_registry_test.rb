# frozen_string_literal: true

require_relative "test_helper"

# P18 (H1/H2) — the Capability::Descriptor/Capability::Source contract and the
# sealed registry's invariant-35/42 guarantees.
#
# - H1: descriptor shape (incl. schemas), digest stability, source shape.
# - H2 (direct): a forged source registration fails (registry sealed);
#   no content path can produce a Capability::Source; the intersection =
#   descriptors ∩ admission set, immutable mid-turn.
class CapabilityRegistryTest < Minitest::Test
  Core = Tamoz::Core
  Capability = Core::Capability

  def descriptor(id: "read_file", kind: :tool, source_id: "local", **overrides)
    Capability::Descriptor.new(
      id:, kind:, source_id:, trust: :local, effect_class: :read_only,
      protocol_profile: {"transport" => "in_process"},
      input_schema: {"type" => "object", "properties" => {}},
      output_schema: {"type" => "object"}, **overrides
    )
  end

  def local_source
    Capability::Source.new(
      source_id: "local",
      descriptors: [descriptor(id: "read_file"), descriptor(id: "list_directory")]
    )
  end

  def registry(sources: [local_source], admission_set: %w[read_file list_directory])
    Capability::Registry.build(sources:, admission_set:)
  end

  # H1: descriptor shape + digest stability.
  def test_descriptor_is_content_addressed_and_validated
    base = descriptor
    assert base.definition_digest.start_with?("sha256:")
    assert_equal base.definition_digest, descriptor.definition_digest
    refute_equal base.definition_digest,
                 descriptor(effect_class: :bounded).definition_digest

    assert_raises(Tamoz::ConfigurationError) { descriptor(kind: :plugin) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(trust: :model_claimed) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(input_schema: "not a hash") }
    assert_raises(Tamoz::ConfigurationError) { descriptor(id: "") }
  end

  # H2a: a forged source registration fails — the registry is sealed.
  def test_forged_source_registration_is_refused
    host = registry
    forged = Capability::Source.new(
      source_id: "forged",
      descriptors: [descriptor(id: "evil", source_id: "forged", trust: :declared)]
    )
    error = assert_raises(Capability::DescriptorConflictError) { host.register(forged) }
    assert_includes error.message, "sealed"
    # The surface is unchanged (lexicographic sort for the assertion).
    assert_equal %w[list_directory read_file], host.names.sort
  end

  # H2b: no content path can produce a Capability::Source — the constructor
  # requires real Capability::Descriptor values, never content hashes.
  def test_no_content_path_can_produce_a_source
    assert_raises(Tamoz::ConfigurationError) do
      Capability::Source.new(
        source_id: "from-content",
        descriptors: [{"id" => "evil", "kind" => "tool"}] # a content hash, not a value
      )
    end
    assert_raises(Tamoz::ConfigurationError) do
      Capability::Source.new(source_id: "bad", descriptors: ["not-a-descriptor"])
    end
  end

  # H2c: the intersection = descriptors ∩ admission set, computed once,
  # immutable mid-turn.
  def test_intersection_is_admission_set_bounded_and_immutable
    host = registry(admission_set: %w[read_file])
    assert_equal %w[read_file], host.names.sort
    assert host.descriptors.key?("read_file")
    refute host.descriptors.key?("list_directory"), "non-admitted descriptors must not surface"

    # Disabled descriptors never surface even if admitted.
    host2 = Capability::Registry.build(
      sources: [Capability::Source.new(
        source_id: "local",
        descriptors: [
          descriptor(id: "read_file"),
          descriptor(id: "disabled_tool", availability: :disabled)
        ]
      )],
      admission_set: %w[read_file disabled_tool]
    )
    refute host2.descriptors.key?("disabled_tool")

    # The surface is frozen (immutable mid-turn).
    assert host.surface.frozen?
    assert_raises(FrozenError) { host.surface["read_file"] = descriptor(id: "other") }
  end

  # H2d: a cross-source descriptor id collision refuses construction.
  def test_cross_source_id_collision_is_refused
    other = Capability::Source.new(
      source_id: "websearch",
      descriptors: [descriptor(id: "read_file", source_id: "websearch", kind: :websearch)]
    )
    assert_raises(Capability::DescriptorConflictError) do
      Capability::Registry.build(
        sources: [local_source, other],
        admission_set: %w[read_file]
      )
    end
  end

  # H2e: source ids are the four built-ins; anything else at construction is a
  # registry-content mismatch (the closed set is enforced by the host, which
  # only builds the four).
  def test_built_in_sources_are_the_closed_set
    assert_equal %w[local skill mcp websearch], Capability::BUILT_IN_SOURCES
  end

  # H2f (critic F4): a source may only carry descriptors that belong to it —
  # descriptor.source_id must match the containing source. A "local" source
  # smuggling an "mcp:" descriptor must refuse construction.
  def test_descriptor_source_consistency_is_enforced
    smuggled = Capability::Source.new(
      source_id: "local",
      descriptors: [
        descriptor(id: "mcp:evil/tool", source_id: "mcp:evil", kind: :mcp_tool)
      ]
    )
    error = assert_raises(Capability::DescriptorConflictError) do
      Capability::Registry.build(
        sources: [smuggled],
        admission_set: %w[mcp:evil/tool]
      )
    end
    assert_includes error.message, "does not belong to"
  end

  # H2g (critic F4): the registry is constructed ONLY through build — direct
  # value construction (Data.define `new`) is refused because it would bypass
  # the closed-world and consistency checks.
  def test_registry_cannot_be_constructed_directly
    assert_raises(NoMethodError) do
      Capability::Registry.new(
        sources: [],
        surface: {},
        names: []
      )
    end
  end

  # H2h (critic F4): a prefixed built-in source id must carry a non-empty
  # suffix — "skill:" with no name is not a valid built-in source.
  def test_empty_built_in_suffix_is_refused
    bare = Capability::Source.new(
      source_id: "skill:",
      descriptors: [descriptor(id: "load_skill", source_id: "skill:", kind: :skill)]
    )
    error = assert_raises(Capability::DescriptorConflictError) do
      Capability::Registry.build(sources: [bare], admission_set: %w[load_skill])
    end
    assert_includes error.message, "not a built-in"
  end
end

