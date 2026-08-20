# frozen_string_literal: true

require_relative "test_helper"

# P18 (H4/C5 + C3/C6) — surface equivalence. The host is a RE-ORG, not a
# surface change: the model-visible ids and descriptions exposed through the
# host are byte-identical to the P18-start committed fixture (captured at
# `a6ffe04`, the P18-start baseline after P11–P14 close) — never against a
# self-computed in-memory expectation.
#
# Also covers the sealed-registry / closed-world guarantees at the host level:
# a forged registration fails, and the host wraps only non-ToolError
# exceptions (C7).
class CapabilityHostTest < Minitest::Test
  Core = Tamoz::Core
  Capability = Core::Capability
  P18_START_FIXTURE = ROOT.join(
    "test", "fixtures", "p18_start_toolbox_surface.json"
  )

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
      "read_only_names" => toolbox.read_only_names.sort,
      "catalog_digest" => toolbox.catalog_digest
    }
  end

  # The host's rendered surface in the same shape as the fixture. The host is
  # the registry + intersection renderer: it reproduces the surface IDs and
  # the read-only split; description text lives in the toolbox (verified
  # byte-identical against the fixture by test 2).
  def host_surface(host)
    {
      "names" => host.registry.names.sort,
      "read_only_names" => host.registry.names.select do |name|
        host.registry.descriptors.fetch(name).effect_class == :read_only
      end.sort
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
        approval_policy: read_only ? :none : :required,
        egress_policy_ref: "none",
        egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
        secret_handling: :reject_values,
        request_budget: { "max_bytes" => 16 * 1024 },
        output_budget: { "max_bytes" => 64 * 1024 },
        retry_policy: read_only ? :read_only : :none,
        reconciliation_policy: :none,
        schema_digest: Capability::Descriptor.schema_digest_for(
          { "type" => "object" }, { "type" => "object" }
        ),
        source_digest: Capability::Descriptor.source_digest_for("local"),
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
        approval_policy: :none,
        egress_policy_ref: "none",
        egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
        secret_handling: :reject_values,
        request_budget: { "max_bytes" => 16 * 1024 },
        output_budget: { "max_bytes" => 64 * 1024 },
        retry_policy: :read_only,
        reconciliation_policy: :none,
        schema_digest: Capability::Descriptor.schema_digest_for(
          { "type" => "object" }, { "type" => "object" }
        ),
        source_digest: Capability::Descriptor.source_digest_for("skill:catalog"),
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

  # H4: the model-visible surface through the host matches the P18-start
  # committed fixture (names + read-only split; description text lives in the
  # toolbox, covered by the fixture test below).
  def test_host_surface_is_byte_identical_to_the_p18_start_fixture
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      fixture = JSON.parse(File.read(P18_START_FIXTURE))

      assert_equal fixture.fetch("names"), host_surface(host).fetch("names")
      assert_equal(
        fixture.fetch("read_only_names"),
        host_surface(host).fetch("read_only_names")
      )
    end
  end

  # H4b: the live toolbox surface equals the committed fixture — the re-org
  # did not change the toolbox itself, and the fixture is the honest
  # P18-start baseline.
  def test_live_toolbox_surface_matches_the_committed_fixture
    with_toolbox do |toolbox|
      fixture = JSON.parse(File.read(P18_START_FIXTURE))
      live = toolbox_surface(toolbox)

      assert_equal fixture.fetch("names"), live.fetch("names")
      assert_equal fixture.fetch("descriptions"), live.fetch("descriptions")
      assert_equal fixture.fetch("read_only_names"), live.fetch("read_only_names")
      assert_equal fixture.fetch("catalog_digest"), live.fetch("catalog_digest")
    end
  end

  # H4c: the read-only/write split is preserved (effect_class derived from the
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
            input_schema: {"type" => "object"}, output_schema: {"type" => "object"},
            approval_policy: :none, egress_policy_ref: "none",
            egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
            secret_handling: :reject_values,
            request_budget: { "max_bytes" => 16 * 1024 },
            output_budget: { "max_bytes" => 64 * 1024 },
            retry_policy: :read_only, reconciliation_policy: :none,
            schema_digest: Capability::Descriptor.schema_digest_for(
              {"type" => "object"}, {"type" => "object"}
            ),
            source_digest: Capability::Descriptor.source_digest_for("forged")
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

      # An unknown descriptor id never reaches a dispatcher: routing refuses it
      # with the host's OWN typed error, so no raw KeyError escapes (invariant
      # 17) and the message names the capability rather than the Ruby fault
      # that used to surface it. The wrap path itself is still covered, by
      # `test_real_host_wraps_untyped_errors` below.
      error = assert_raises(Tamoz::Tools::ToolError) do
        host.dispatch("nonexistent", {}, context: {})
      end
      # The text is `Toolbox#validate`'s, byte for byte: structural review
      # feeds a rejection reason into the planning prompt, so this string is
      # part of the model-visible surface (invariant 16, C7).
      assert_equal 'unknown tool "nonexistent"', error.message
      refute_kind_of KeyError, error
    end
  end

  # H6 (critic F5): the REAL host dispatch success path — a bound dispatcher
  # runs validate then execute through `CapabilityHost#dispatch` and returns
  # the typed result.
  def test_real_host_dispatch_success_path
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      host.bind_dispatcher("local", real_dispatcher)

      result = host.dispatch("read_file", {"path" => "a.txt"}, context: {})
      assert_equal({"read" => "a.txt"}, result)
    end
  end

  # H6 (critic F5): a typed ToolError (D-7 taxonomy) raised by a real
  # dispatcher passes through `CapabilityHost#dispatch` with class AND
  # message bytes identical — the host does not wrap it.
  def test_real_host_typed_error_passes_through_unchanged
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      host.bind_dispatcher("local", rejecting_dispatcher)

      message = "path is required"
      error = assert_raises(Tamoz::Core::ToolArgumentError) do
        host.dispatch("read_file", {}, context: {})
      end
      assert_equal message, error.message
      assert error.repairable?
    end
  end

  # C7 (critic F5): an untyped exception from a real dispatcher is wrapped at
  # the boundary as ToolError; no raw RuntimeError escapes the host.
  def test_real_host_wraps_untyped_errors
    with_toolbox do |toolbox|
      host = host_from_toolbox(toolbox)
      host.bind_dispatcher("local", exploding_dispatcher)

      error = assert_raises(Tamoz::Tools::ToolError) do
        host.dispatch("read_file", {"path" => "a.txt"}, context: {})
      end
      assert_includes error.message, "boom"
    end
  end

  private

  def dispatcher_stub
    Object.new.tap do |stub|
      stub.define_singleton_method(:validate) { |_d, _a| :ok }
      stub.define_singleton_method(:execute) { |_d, _a, context:| {"ok" => true} }
    end
  end

  # A real per-source dispatcher implementing the P18 interface:
  # validate(descriptor, arguments) + execute(descriptor, arguments, context:).
  def real_dispatcher
    Object.new.tap do |dispatcher|
      dispatcher.define_singleton_method(:validate) do |descriptor, arguments|
        unless arguments.is_a?(Hash) && arguments.key?("path")
          raise Tamoz::Core::ToolArgumentError, "path is required"
        end
        :ok
      end
      dispatcher.define_singleton_method(:execute) do |_descriptor, arguments, _context|
        {"read" => arguments.fetch("path")}
      end
    end
  end

  def rejecting_dispatcher
    Object.new.tap do |dispatcher|
      dispatcher.define_singleton_method(:validate) do |_descriptor, arguments|
        raise Tamoz::Core::ToolArgumentError, "path is required" unless arguments.key?("path")

        :ok
      end
      dispatcher.define_singleton_method(:execute) { |_d, arguments, _c| {"read" => arguments.fetch("path")} }
    end
  end

  def exploding_dispatcher
    Object.new.tap do |dispatcher|
      dispatcher.define_singleton_method(:validate) { |_d, _a| :ok }
      dispatcher.define_singleton_method(:execute) { |_d, _a, _c| raise "boom" }
    end
  end
end
