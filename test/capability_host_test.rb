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
#
# This file also owns the binding layer (P15-W, docs/P18_CAPABILITY_HOST_PLAN.md
# §9): how the host is wired into real session construction — surface order,
# source split, admission bounding, per-source routing, and exception semantics.
# Host and binding layers stay in one class deliberately (audit cluster 1:
# they assert the same surface from two layers), so the size gate is waived.

# rubocop:disable Metrics/ClassLength
class CapabilityHostTest < Minitest::Test
  Core = Tamoz::Core
  Capability = Core::Capability
  P18_START_FIXTURE = ROOT.join(
    "test", "fixtures", "p18_start_toolbox_surface.json"
  )

  # A descriptor honouring exactly the P10 §3 duck-type contract: id, name,
  # source_id, definition_digest, effect_class. Nothing more — a host that
  # reads a richer field would reject a conforming caller.
  Descriptor = Struct.new(:id, :name, :source_id, :definition_digest, :effect_class)

  # Records every call the session routes to the MCP side, so "the decision
  # reached this source's dispatcher" is proven by observation, not by reading
  # the wiring.
  class RecordingMcpSource
    attr_reader :calls, :descriptors, :names, :read_only_names, :catalogs, :mcp_catalogs

    def initialize(descriptors)
      @descriptors = descriptors
      @index = descriptors.to_h { |descriptor| [descriptor.id, descriptor] }
      @names = descriptors.map(&:id)
      @read_only_names = descriptors.select { |d| d.effect_class == :read_only }.map(&:id)
      @catalogs = {"test-server" => :snapshot}
      @mcp_catalogs = {"test-server" => "sha256:pinned"}
      @calls = []
    end

    def name?(name) = @index.key?(String(name))
    def descriptor_for(name) = @index[String(name)]
    def read_only?(name) = @index.fetch(String(name)).effect_class == :read_only
    def maximum_effect_output_bytes(_name) = record(:maximum_effect_output_bytes) { 64 * 1024 }
    def validate(name, arguments) = record(:validate, name) { arguments }
    def preview(name, _arguments) = record(:preview, name) { "preview #{name}" }
    def effect_intent(name, _arguments) = record(:effect_intent, name) { {"remote" => name} }
    def execute(_context, name, _arguments) = record(:execute, name) { "executed #{name}" }
    def empty? = @catalogs.empty?
    def effect_intent_builder = nil

    private

    def record(method, name = nil)
      @calls << [method, name]
      yield
    end
  end

  def with_toolbox(**options)
    Dir.mktmpdir("tamoz-host") do |directory|
      yield Tamoz::Tools::Toolbox.new(root: directory, allow_changes: true, **options)
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

  # C3/C6: the registry is SEALED at construction. A forged registration fails
  # on the hand-built host and on the LIVE session binding; an unregistered
  # source cannot acquire a dispatcher; and a registered source's
  # implementation cannot be swapped after construction — a sealed surface with
  # a replaceable implementation is not sealed.
  def test_the_sealed_registry_refuses_forged_registrations_and_dispatcher_swaps
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

    with_toolbox do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)
      local_forged = local_source_with_forged_descriptor

      assert_raises(Capability::DescriptorConflictError) { binding.registry.register(local_forged) }
      assert_raises(Capability::DescriptorConflictError) do
        binding.host.bind_dispatcher("mcp:forged", Object.new)
      end
      assert_raises(Capability::DescriptorConflictError) do
        binding.host.bind_dispatcher("local", Object.new)
      end
      refute binding.descriptor?("exfiltrate")
    end
  end

  def local_source_with_forged_descriptor
    Capability::Source.new(
      source_id: "local",
      descriptors: [
        Capability::Descriptor.new(
          id: "exfiltrate", kind: :tool, source_id: "local", trust: :local,
          effect_class: :read_only, protocol_profile: {},
          approval_policy: :none, egress_policy_ref: "none",
          egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
          secret_handling: :reject_values,
          request_budget: { "max_bytes" => 16 * 1024 },
          output_budget: { "max_bytes" => 64 * 1024 },
          retry_policy: :read_only, reconciliation_policy: :none,
          schema_digest: Capability::Descriptor.schema_digest_for(nil, nil),
          source_digest: Capability::Descriptor.source_digest_for("local")
        )
      ]
    )
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

  # ORDER matters: the tool list is rendered into the planning prompt, so a
  # reordering would move the prompt bytes and the cache epoch with them
  # (invariant 16). The binding must reproduce the toolbox's own catalog order.
  def test_surface_order_matches_the_pre_wiring_computation
    with_toolbox do |toolbox|
      source = mcp_source
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:, mcp: source)

      assert_equal (toolbox.names + source.names).uniq, binding.names(:action)
      assert_equal (toolbox.read_only_names + source.read_only_names).uniq,
                   binding.names(:discovery)
    end
  end

  # A toolbox with skills splits into two built-in sources — `local` and
  # `skill:<epoch>` — while the model-visible ids stay bare (P18 C5).
  def test_skill_tools_register_under_the_skill_source_with_bare_ids
    Dir.mktmpdir("tamoz-binding-skills") do |directory|
      root = File.join(directory, "workspace")
      operator = File.join(directory, "skills", "review")
      FileUtils.mkdir_p(root)
      FileUtils.mkdir_p(operator)
      File.write(
        File.join(operator, "SKILL.md"),
        "---\nname: review\ndescription: A bounded review procedure.\n---\nBody.\n"
      )
      snapshot = Tamoz::Tools::Skills::Compiler.new(
        sources: [
          Tamoz::Tools::Skills::SkillSource.new(
            id: "operator", root: File.join(directory, "skills"), trust: "operator"
          )
        ]
      ).compile
      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true, skills: snapshot)
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)

      source_ids = binding.registry.sources.map(&:source_id)

      assert_includes source_ids, "local"
      assert(source_ids.any? { |id| id.start_with?("skill:") },
             "a skill-bearing toolbox must register a skill source: #{source_ids.inspect}")
      descriptor = binding.registry.descriptors.fetch("load_skill")

      assert_equal :skill, descriptor.kind
      assert_equal :declared, descriptor.trust
      assert_equal "load_skill", descriptor.id
    end
  end

  # Websearch is one of the four built-in sources, not an unnamed extra MCP
  # server — while keeping its pinned `mcp:websearch/...` model-visible id.
  def test_websearch_registers_under_the_websearch_built_in_source
    with_toolbox do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:, mcp: mcp_source)
      descriptor = binding.registry.descriptors.fetch("mcp:websearch/search")

      assert_equal :websearch, descriptor.kind
      assert_equal "websearch:websearch", descriptor.source_id
      assert_equal "mcp:test-server", binding.registry.descriptors
                                             .fetch("mcp:test-server/echo").source_id
    end
  end

  # Invariant 35: the surface is descriptors ∩ the POLICY-DERIVED admission
  # set. A tool the profile withheld can never be dispatched, even though the
  # toolbox class knows how to run it.
  def test_the_admission_set_bounds_the_surface
    with_toolbox(allowed_tools: %w[read_file list_directory]) do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)

      assert_equal %w[read_file list_directory], binding.names(:action)
      assert_equal toolbox.names, binding.names(:action)
      assert_equal toolbox.read_only_names, binding.names(:discovery)
      refute binding.descriptor?("apply_patch")
      assert_raises(Tamoz::Agent::ToolError) { binding.safety("apply_patch", {}) }
    end
  end

  # Every decision the session makes about an MCP capability reaches the MCP
  # source — proven by the source's own call log, not by reading the wiring.
  def test_every_decision_routes_to_the_owning_sources_dispatcher
    with_toolbox do |toolbox|
      source = mcp_source
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:, mcp: source)

      binding.maximum_effect_output_bytes("mcp:test-server/write")
      binding.preview("mcp:test-server/write", {"value" => "x"})
      binding.effect_intent("mcp:test-server/write", {"value" => "x"})
      binding.validate("mcp:test-server/write", {"value" => "x"})
      binding.execute(nil, "mcp:test-server/write", {"value" => "x"})

      methods = source.calls.map(&:first)

      assert_includes methods, :maximum_effect_output_bytes
      assert_includes methods, :preview
      assert_includes methods, :effect_intent
      assert_includes methods, :execute
      assert(source.calls.all? { |_method, name| name.nil? || name.start_with?("mcp:") },
             "an MCP decision must never be asked about a local tool: #{source.calls.inspect}")
    end
  end

  # A local decision never reaches the MCP source: the two sources are separate
  # dispatchers, and the host holds no source-typed branch that could confuse
  # them. Approval classification lives in the descriptor metadata the binding
  # synthesizes (:none for read-only surface, :required otherwise) — never in a
  # dispatcher method.
  def test_local_decisions_never_reach_the_mcp_source
    with_toolbox do |toolbox|
      source = mcp_source
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:, mcp: source)

      assert_equal :required, binding.registry.descriptors.fetch("apply_patch").approval_policy
      assert_equal :none, binding.registry.descriptors.fetch("read_file").approval_policy
      assert_equal :reconcilable, binding.safety("apply_patch", {})
      assert_equal :read_only, binding.safety("read_file", {})
      assert_equal 6 * 1024, binding.maximum_effect_output_bytes("apply_patch")
      assert_empty source.calls
    end
  end

  # MCP safety is `:unsafe` unless the caller declared the capability
  # read-only: an ambiguous remote outcome must stop, never repeat
  # (invariants 21/37). The same declaration drives the descriptor's
  # approval_policy metadata.
  def test_mcp_safety_defaults_to_unsafe_and_read_only_is_declared
    with_toolbox do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:, mcp: mcp_source)

      assert_equal :unsafe, binding.safety("mcp:test-server/write", {})
      assert_equal :read_only, binding.safety("mcp:test-server/echo", {})
      assert_equal :required, binding.registry.descriptors.fetch("mcp:test-server/write").approval_policy
      assert_equal :none, binding.registry.descriptors.fetch("mcp:test-server/echo").approval_policy
    end
  end

  # Invariant 17: storage failures, cancellations and programmer bugs must
  # PROPAGATE out of tool execution; only recoverable tool failures become
  # values. `CapabilityHost#dispatch` wraps every untyped exception into a
  # `ToolError`, and `EffectDispatcher` records a `ToolError` as tool EVIDENCE —
  # so routing the session's execution through `dispatch` would have converted
  # an `Errno::ENOSPC` or a `NoMethodError` into something the agent could try
  # to repair around. The binding routes with `route` and calls the dispatcher
  # itself, keeping the pre-host exception semantics exactly.
  def test_execution_propagates_untyped_failures_instead_of_making_them_evidence
    with_toolbox do |toolbox|
      # The failure is injected into the REAL toolbox the real LocalDispatcher
      # forwards to — the whole production path, not a stand-in dispatcher.
      toolbox.define_singleton_method(:execute) do |_name, _arguments|
        raise Errno::ENOSPC, "no space left on device"
      end
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)

      assert_raises(Errno::ENOSPC) do
        binding.execute(nil, "read_file", {"path" => "a.txt"})
      end

      # The host's own `dispatch` still wraps, exactly as P18 shipped it: this
      # asserts the two paths differ on purpose rather than by accident.
      assert_raises(Tamoz::Tools::ToolError) do
        binding.host.dispatch("read_file", {"path" => "a.txt"}, context: nil)
      end
    end
  end

  # A typed, repairable tool failure DOES become evidence — the other half of
  # invariant 17 — and reaches the caller with its class and message intact.
  def test_execution_passes_typed_tool_errors_through_with_identity
    with_toolbox do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)

      error = assert_raises(Tamoz::Core::ToolArgumentError) do
        binding.validate("read_file", {"path" => 42})
      end

      assert error.repairable?
      assert_equal "path must be a string", error.message

      # A policy rejection is typed too, and is NOT repairable.
      policy = assert_raises(Tamoz::Core::ToolPolicyError) do
        binding.validate("read_file", {"path" => "/etc/passwd"})
      end

      refute_predicate policy, :repairable?
    end
  end

  # Old-session resume compatibility. Nothing about the host is persisted: a
  # resumed session rebuilds it from the same pins, so the descriptor digests
  # must be deterministic. If they were not, a session written before the host
  # existed could resume onto a different surface than it was planned against
  # (invariant 41/35), which is exactly what the resume guards forbid.
  def test_host_construction_is_deterministic_across_sessions
    Dir.mktmpdir("tamoz-binding-determinism") do |root|
      first = Tamoz::Agent::CapabilityBinding.build(
        toolbox: Tamoz::Tools::Toolbox.new(root:, allow_changes: true)
      )
      second = Tamoz::Agent::CapabilityBinding.build(
        toolbox: Tamoz::Tools::Toolbox.new(root:, allow_changes: true)
      )

      assert_equal first.names(:action), second.names(:action)
      assert_equal(
        first.registry.descriptors.transform_values(&:definition_digest),
        second.registry.descriptors.transform_values(&:definition_digest)
      )
      assert_equal first.registry.sources.map(&:source_id),
                   second.registry.sources.map(&:source_id)
    end
  end

  # A thread written by one Session object resumes on a NEW Session object —
  # the ordinary resume path — and the rebuilt host exposes the identical
  # surface. The host adds no field to the session record, so a record written
  # before the wiring reads back unchanged.
  def test_a_thread_resumes_onto_an_identically_rebuilt_surface
    Dir.mktmpdir("tamoz-binding-resume") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "note.txt"), "hello\n")
      database = File.join(directory, "tamoz.db")

      first_digests = nil
      with_session(database, root) do |session|
        session.start(
          "read note.txt", thread: "resumed", request_id: "request.one"
        )
        first_digests = session.capabilities.registry.descriptors
                               .transform_values(&:definition_digest)
      end

      with_session(database, root) do |session|
        # The resume guards run against the rebuilt surface and stay silent.
        session.verify_skill_binding!(thread: "resumed")
        session.verify_mcp_binding!(thread: "resumed")
        session.verify_egress_binding!(thread: "resumed")
        view = session.view(thread: "resumed")

        assert_equal :completed, view.status
        assert_equal(
          first_digests,
          session.capabilities.registry.descriptors.transform_values(&:definition_digest)
        )
        refute_includes view.state.fetch(:session).keys, "capability_host",
                        "the host must add no field to the session record"
      end
    end
  end

  # A conforming source with exactly one required method removed, so respond_to?
  # reports it missing. The preflight list must name every method the session
  # actually calls, not a subset (audit EU-001).
  def test_session_construction_rejects_an_mcp_source_missing_a_called_method
    Dir.mktmpdir("tamoz-binding-negative") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
      model = Object.new
      model.define_singleton_method(:generate) { |**| raise "no model call expected before preflight" }
      begin
        %i[descriptors descriptor_for].each do |method|
          error = assert_raises(ArgumentError, "removing #{method} must fail preflight") do
            Tamoz::Agent::Session.new(
              model:,
              toolbox: Tamoz::Tools::Toolbox.new(root:, allow_changes: true),
              checkpointer: adapter,
              mcp: source_without(method)
            )
          end
          assert_includes error.message, "mcp source must respond to"
          assert_includes error.message, method.to_s
        end
      ensure
        adapter.close
      end
    end
  end

  # The session builds its host at CONSTRUCTION, once, and the nodes hold it.
  def test_the_session_builds_its_capability_host_at_construction
    Dir.mktmpdir("tamoz-binding-session") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
      begin
        model = Object.new
        model.define_singleton_method(:generate) { |**| raise "no model call expected" }
        session = Tamoz::Agent::Session.new(
          model:,
          toolbox: Tamoz::Tools::Toolbox.new(root:, allow_changes: true),
          checkpointer: adapter
        )
        binding = session.capabilities

        assert_kind_of Tamoz::Agent::CapabilityBinding, binding
        assert_kind_of Tamoz::Tools::CapabilityHost, binding.host
        assert_equal %w[local], binding.registry.sources.map(&:source_id)
        assert binding.registry.frozen?
      ensure
        adapter.close
      end
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

  def mcp_source
    RecordingMcpSource.new(
      [
        Descriptor.new("mcp:test-server/echo", "echo", "test-server", "sha256:e", :read_only),
        Descriptor.new("mcp:test-server/write", "write", "test-server", "sha256:w", :bounded),
        Descriptor.new("mcp:websearch/search", "search", "websearch", "sha256:s", :read_only)
      ]
    )
  end

  def source_without(method)
    source = mcp_source
    source.singleton_class.send(:undef_method, method)
    source
  end

  def with_session(database, root)
    adapter = Tamoz::SQLite::Adapter.new(path: database)
    begin
      model = Object.new
      model.define_singleton_method(:generate) do |stage:, system:, prompt:|
        case stage
        when :plan
          JSON.generate(
            "goal" => "read the note", "done_when" => ["the file was read"],
            "steps" => [{"id" => "s1", "purpose" => "read it", "tool" => "read_file",
                         "arguments" => {"path" => "note.txt"},
                         "verification" => "the content is returned"}]
          )
        when :review
          JSON.generate("decision" => "accept", "issues" => [], "rationale" => "bounded")
        else
          JSON.generate("answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"])
        end
      end
      yield Tamoz::Agent::Session.new(
        model:,
        toolbox: Tamoz::Tools::Toolbox.new(root:),
        checkpointer: adapter,
        approval_engine: Tamoz::Agent.build_approval_engine(profile_name: "implement"),
        approval_session_id: "binding-resume"
      )
    ensure
      adapter.close
    end
  end
end

# rubocop:enable Metrics/ClassLength
