# frozen_string_literal: true

require_relative "test_helper"

# P15-W (docs/P18_CAPABILITY_HOST_PLAN.md §9) — the P18 capability host is now
# bound into real session construction. P18 shipped the contract and deferred
# the wiring; these are the proofs the deferral asked P15 to produce:
#
#   * the registry is built at session construction from the four built-in
#     sources and SEALED (a forged registration fails on the live session);
#   * the model-visible surface is byte-identical to the committed P18-start
#     fixture and to the pre-wiring computation, in ORDER (invariant 16);
#   * every tool-facing decision reaches the per-source dispatcher of the
#     descriptor's own source — no decision is answered by another source;
#   * an MCP/websearch capability registers under its own built-in source.
class AgentCapabilityBindingTest < Minitest::Test
  Capability = Tamoz::Core::Capability
  P18_START_FIXTURE = ROOT.join("test", "fixtures", "p18_start_toolbox_surface.json")

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
    Dir.mktmpdir("tamoz-binding") do |directory|
      yield Tamoz::Tools::Toolbox.new(root: directory, allow_changes: true, **options)
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

  # The surface the model sees, through the production binding, is the
  # committed P18-start fixture — the same file P18's own H4 compares against.
  def test_production_surface_is_byte_identical_to_the_p18_start_fixture
    with_toolbox do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)
      fixture = read_json(P18_START_FIXTURE)

      assert_equal fixture.fetch("names"), binding.names(:action).sort
      assert_equal fixture.fetch("read_only_names"), binding.names(:discovery).sort
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

  # C3/C6 on the LIVE session: the registry a real session built is sealed.
  def test_a_live_session_registry_refuses_a_forged_registration
    with_toolbox do |toolbox|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox:)
      forged = Capability::Source.new(
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

      assert_raises(Capability::DescriptorConflictError) { binding.registry.register(forged) }
      # An unregistered source cannot acquire a dispatcher …
      assert_raises(Capability::DescriptorConflictError) do
        binding.host.bind_dispatcher("mcp:forged", Object.new)
      end
      # … and a registered source's implementation cannot be swapped after
      # construction: a sealed surface with a replaceable implementation is
      # not sealed.
      assert_raises(Capability::DescriptorConflictError) do
        binding.host.bind_dispatcher("local", Object.new)
      end
      refute binding.descriptor?("exfiltrate")
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

      refute policy.repairable?
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
  def source_without(method)
    source = mcp_source
    source.singleton_class.send(:undef_method, method)
    source
  end

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
end
