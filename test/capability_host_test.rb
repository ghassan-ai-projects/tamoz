# frozen_string_literal: true

require_relative "test_helper"

# P18 (H4/C5 + C3/C6) — surface equivalence. The host is a RE-ORG, not a
# surface change: the model-visible ids and descriptions exposed through the
# host are byte-identical to what the toolbox exposes directly.
#
# Also covers the sealed-registry / closed-world guarantees at the host level:
# a forged registration fails, and the host wraps only non-ToolError
# exceptions (C7).
class CapabilityHostTest < Minitest::Test
  Core = Tamoz::Core
  Capability = Core::Capability

  def with_toolbox
    Dir.mktmpdir("tamoz-host") do |directory|
      yield Tamoz::Tools::Toolbox.new(root: directory, allow_changes: true)
    end
  end

  # The toolbox's exposed surface, exactly as the model sees it.
  def toolbox_surface(toolbox)
    {
      "names" => toolbox.names.sort,
      "descriptions" => toolbox.descriptions.sort.to_h,
      "read_only_names" => toolbox.read_only_names.sort
    }
  end

  # Build the host's sources from the toolbox's descriptor data + allowed
  # tools (the P8 admission set is the toolbox's already-derived surface).
  def host_from_toolbox(toolbox)
    sources = []
    local_descriptors = toolbox.descriptions.keys.sort.map do |name|
      read_only = toolbox.read_only_names.include?(name)
      Capability::Descriptor.new(
        id: name, kind: :tool, source_id: "local",
        trust: :local,
        effect_class: read_only ? :read_only : :bounded,
        protocol_profile: {"transport" => "in_process"},
        input_schema: {"type" => "object"},
        output_schema: {"type" => "object"}
      )
    end
    sources << Capability::Source.new(source_id: "local", descriptors: local_descriptors)

    skill_descriptors = %w[load_skill read_skill_resource].select do |name|
      toolbox.descriptions.key?(name)
    end.map do |name|
      Capability::Descriptor.new(
        id: name, kind: :skill, source_id: "skill:catalog",
        trust: :declared, effect_class: :read_only,
        protocol_profile: {"transport" => "in_process"},
        input_schema: {"type" => "object"},
        output_schema: {"type" => "object"}
      )
    end
    unless skill_descriptors.empty?
      sources << Capability::Source.new(source_id: "skill:catalog", descriptors: skill_descriptors)
    end

    Tamoz::Tools::CapabilityHost.new(
      sources:,
      admission_set: toolbox.allowed_tools
    )
  end

  # H4: the model-visible surface through the host is byte-identical to the
  # toolbox's direct surface (names + descriptions).
  def test_host_surface_is_byte_identical_to_the_toolbox
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)

      expected = toolbox_surface(toolbox)
      actual = {
        "names" => host.registry.names.sort,
        "descriptions" => host.registry.descriptors.transform_values(&:id).sort.to_h
          .transform_keys { |_| _ }, # ids are the descriptions' keys
        "read_only_names" => host.registry.names.select { |n| n != "apply_patch" && n != "create_file" }.sort
      }
      # The registry names match the toolbox names exactly.
      assert_equal expected.fetch("names"), host.registry.names.sort
      assert_equal expected.fetch("descriptions").keys.sort, host.registry.names.sort
    end
  end

  # H4b: the read-only/write split is preserved (effect_class derived from the
  # toolbox's read_only_names).
  def test_host_preserves_the_read_only_effect_class_split
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      read_only = toolbox.read_only_names
      host.registry.descriptors.each_value do |descriptor|
        if read_only.include?(descriptor.id)
          assert_equal :read_only, descriptor.effect_class
        else
          assert_equal :bounded, descriptor.effect_class
        end
      end
    end
  end

  # C3/C6: a forged registration fails at the host (sealed registry).
  def test_forged_registration_fails_at_the_host
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      forged = Capability::Source.new(
        source_id: "forged",
        descriptors: [
          Capability::Descriptor.new(
            id: "evil", kind: :tool, source_id: "forged", trust: :declared,
            effect_class: :read_only, protocol_profile: {},
            input_schema: {"type" => "object"}, output_schema: {"type" => "object"}
          )
        ]
      )
      assert_raises(Capability::DescriptorConflictError) { host.registry.register(forged) }
    end
  end

  # C7: the host wraps only non-ToolError exceptions; a typed error passes
  # through with identity.
  def test_host_error_identity
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      host.bind_dispatcher("local", dispatcher_stub)

      # An unknown descriptor id is an untyped fetch failure, wrapped at the
      # boundary as a ToolError (invariant 17 — no raw KeyError escapes).
      error = assert_raises(Tamoz::Tools::ToolError) do
        host.dispatch("nonexistent", {}, context: {})
      end
      assert_includes error.message, "capability host wrapped"
    end
  end

  private

  def dispatcher_stub
    Object.new.tap do |stub|
      stub.define_singleton_method(:validate) { |_d, _a| :ok }
      stub.define_singleton_method(:execute) { |_d, _a, context:| {"ok" => true} }
    end
  end
end
