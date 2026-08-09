# frozen_string_literal: true

require_relative "test_helper"

# P10 slice 4: the caller-supplied McpCapabilitySource and its session wiring —
# catalog pinning in the session record, the resume guard (fails closed), and the
# caller-level exactly-once proof for the MCP reissue path (invariant 21, advB).
class AgentMcpCapabilitySourceTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets
  Catalog = Tamoz::Mcp::Catalog
  Supervisor = Tamoz::Mcp::Supervisor
  Invocation = Tamoz::Mcp::Invocation
  Elicitation = Tamoz::Mcp::Elicitation
  Source = Tamoz::Agent::McpCapabilitySource

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze
  FLAG_NAMES = %w[
    MCP_TEST_SERVER_MALFORMED_FRAMES MCP_TEST_SERVER_MALFORMED_MID_CALL
    MCP_TEST_SERVER_EXIT_MID_CALL MCP_TEST_SERVER_OVERSIZE_OUTPUT
    MCP_TEST_SERVER_EXTRA_TOOLS MCP_TEST_SERVER_LONG_DESCRIPTION
    MCP_TEST_SERVER_PROTOCOL_VERSION MCP_TEST_SERVER_GRANDCHILD
  ].freeze

  FakeEntry = Data.define(:name, :definition_digest, :description) do
    def initialize(name:, definition_digest:, description: nil)
      super(
        name: name.dup.freeze,
        definition_digest: definition_digest.dup.freeze,
        description: description&.dup&.freeze
      )
    end
  end

  FakeSnapshot = Data.define(:server_id, :snapshot_digest, :entries) do
    def initialize(server_id:, snapshot_digest:, entries:)
      super(
        server_id: server_id.dup.freeze,
        snapshot_digest: snapshot_digest.dup.freeze,
        entries: entries.freeze
      )
    end
  end

  FakeDescriptor = Data.define(
    :id, :name, :source_id, :definition_digest, :input_schema, :effect_class, :protocol_profile
  ) do
    def initialize(id:, name:, source_id:, definition_digest:, input_schema: {}, effect_class: :unknown_effects, protocol_profile: "2026-07-28")
      super(
        id: id.dup.freeze, name: name.dup.freeze, source_id: source_id.dup.freeze,
        definition_digest: definition_digest.dup.freeze,
        input_schema: input_schema, effect_class: effect_class.to_sym,
        protocol_profile: protocol_profile.dup.freeze
      )
    end

    def read_only? = effect_class == :read_only
  end

  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  # Real SDK client that counts every wire request without changing the wire.
  # The SDK's `call_tool` funnels through `request`, so `request` is the single
  # counting point and nothing is double-counted.
  class CountingClient < MCP::Client
    def initialize(transport, wires)
      @wires = wires
      super(transport: transport)
    end

    def request(method:, params: nil, **)
      @wires << {
        method: method,
        name: params.is_a?(Hash) ? params[:name] : nil,
        params: params
      }
      super
    end
  end

  def setup
    @dir = Dir.mktmpdir("tamoz-agent-mcp")
    @saved_flags = ENV.to_h.slice(*FLAG_NAMES)
  end

  def teardown
    FLAG_NAMES.each { |name| ENV.delete(name) }
    @saved_flags.each { |name, value| ENV[name] = value }
    FileUtils.remove_entry(@dir)
  end

  # --- source construction ------------------------------------------------------

  def fake_snapshot(server_id: "test-server", digest: "sha256:#{"a" * 64}", names: %w[echo set_answer], descriptions: {})
    entries = names.map do |name|
      FakeEntry.new(
        name:,
        definition_digest: "sha256:#{name}#{"b" * 44}",
        description: descriptions.fetch(name, nil)
      )
    end
    FakeSnapshot.new(server_id:, snapshot_digest: digest, entries:)
  end

  def fake_descriptor(snapshot, name, effect_class: :unknown_effects)
    entry = snapshot.entries.find { |candidate| candidate.name == name }
    FakeDescriptor.new(
      id: "mcp:#{snapshot.server_id}/#{name}",
      name:,
      source_id: snapshot.server_id,
      definition_digest: entry.definition_digest,
      effect_class:
    )
  end

  def recording_executor
    calls = []
    executor = lambda do |context, descriptor, arguments|
      calls << {context:, descriptor:, arguments:}
      "output of #{descriptor.id}"
    end
    [executor, calls]
  end

  def test_source_pins_catalog_digests_and_derives_the_surface
    snapshot = fake_snapshot
    descriptors = [
      fake_descriptor(snapshot, "echo", effect_class: :read_only),
      fake_descriptor(snapshot, "set_answer", effect_class: :unknown_effects)
    ]
    executor, = recording_executor

    source = Source.new(catalogs: {snapshot.server_id => snapshot}, descriptors:, executor:)

    assert_equal({"test-server" => snapshot.snapshot_digest}, source.mcp_catalogs)
    assert_equal %w[mcp:test-server/echo mcp:test-server/set_answer], source.names
    assert_equal ["mcp:test-server/echo"], source.read_only_names
    assert source.name?("mcp:test-server/echo")
    refute source.name?("set_answer"), "a bare name is never part of the surface"
    refute source.name?("mcp:test-server/../escape")
    assert source.read_only?("mcp:test-server/echo")
    refute source.read_only?("mcp:test-server/set_answer")
    assert source.approval_required?("mcp:test-server/set_answer")
    refute source.approval_required?("mcp:test-server/echo")
    assert_equal snapshot.snapshot_digest, source.mcp_catalogs.fetch("test-server")
    assert_equal(
      snapshot.entries.find { |candidate| candidate.name == "echo" }.definition_digest,
      source.descriptor_for("mcp:test-server/echo").definition_digest
    )
    assert_predicate source, :frozen?
    refute source.empty?
  end

  def test_source_rejects_unqualified_or_unpinned_descriptors
    snapshot = fake_snapshot
    entry = snapshot.entries.find { |candidate| candidate.name == "echo" }
    bare = FakeDescriptor.new(
      id: "echo", name: "echo", source_id: snapshot.server_id,
      definition_digest: entry.definition_digest
    )
    error = assert_raises(ArgumentError) do
      Source.new(catalogs: {snapshot.server_id => snapshot}, descriptors: [bare], executor: ->(_, _, _) {})
    end
    assert_match(/source-qualified/, error.message)

    tampered = FakeDescriptor.new(
      id: "mcp:test-server/echo", name: "echo", source_id: snapshot.server_id,
      definition_digest: "sha256:#{"0" * 64}"
    )
    error = assert_raises(ArgumentError) do
      Source.new(catalogs: {snapshot.server_id => snapshot}, descriptors: [tampered], executor: ->(_, _, _) {})
    end
    assert_match(/definition digest does not match/, error.message)

    orphan = fake_descriptor(snapshot, "echo")
    error = assert_raises(ArgumentError) do
      Source.new(catalogs: {}, descriptors: [orphan], executor: ->(_, _, _) {})
    end
    assert_match(/no pinned catalog/, error.message)

    dup = [fake_descriptor(snapshot, "echo"), fake_descriptor(snapshot, "echo")]
    error = assert_raises(ArgumentError) do
      Source.new(catalogs: {snapshot.server_id => snapshot}, descriptors: dup, executor: ->(_, _, _) {})
    end
    assert_match(/duplicate MCP capability name/, error.message)
  end

  def test_source_validate_is_shallow_and_delegates_no_io
    snapshot = fake_snapshot
    descriptor = fake_descriptor(snapshot, "echo")
    validated = []
    validator = lambda do |entry, arguments|
      validated << [entry.id, arguments]
    end
    source = Source.new(
      catalogs: {snapshot.server_id => snapshot}, descriptors: [descriptor],
      executor: ->(_, _, _) {}, validator:
    )

    assert_equal({"a" => 1}, source.validate("mcp:test-server/echo", {"a" => 1}))
    assert_equal [["mcp:test-server/echo", {"a" => 1}]], validated

    error = assert_raises(Tamoz::Agent::ToolArgumentError) do
      source.validate("mcp:test-server/echo", ["not", "an", "object"])
    end
    assert error.repairable?

    deep = "leaf"
    105.times { deep = {"nested" => deep} }
    error = assert_raises(Tamoz::Agent::ToolArgumentError) do
      source.validate("mcp:test-server/echo", {"value" => deep})
    end
    assert_match(/nesting/, error.message)
    assert_equal 1, validated.length, "the validator is never called for malformed arguments"
  end

  def test_source_execute_preview_and_effect_intent_delegate_to_the_caller
    snapshot = fake_snapshot
    descriptors = [fake_descriptor(snapshot, "set_answer")]
    executor, calls = recording_executor
    previewer = ->(descriptor, arguments) { "preview #{descriptor.id} #{arguments.inspect}" }
    builder = ->(descriptor, arguments) { {"caller_key" => "x"} }
    source = Source.new(
      catalogs: {snapshot.server_id => snapshot}, descriptors:,
      executor:, previewer:, effect_intent_builder: builder
    )

    output = source.execute(:context, "mcp:test-server/set_answer", {"answer" => "42"})
    assert_equal "output of mcp:test-server/set_answer", output
    assert_equal [["mcp:test-server/set_answer", {"answer" => "42"}]],
                 calls.map { |call| [call.fetch(:descriptor).id, call.fetch(:arguments)] }

    arguments = {"answer" => "42"}

    assert_equal "preview mcp:test-server/set_answer #{arguments.inspect}",
                 source.preview("mcp:test-server/set_answer", arguments)
    assert_equal({"caller_key" => "x"},
                 source.effect_intent("mcp:test-server/set_answer", {"answer" => "42"}))

    error = assert_raises(Tamoz::Agent::ToolError) do
      source.execute(:context, "mcp:test-server/unknown", {})
    end
    assert_match(/unknown tool/, error.message)
  end

  def test_source_preview_default_never_renders_server_payload
    snapshot = fake_snapshot
    descriptor = fake_descriptor(snapshot, "set_answer")
    source = Source.new(
      catalogs: {snapshot.server_id => snapshot}, descriptors: [descriptor],
      executor: ->(_, _, _) {}
    )

    preview = source.preview("mcp:test-server/set_answer", {"answer" => "42"})
    assert_includes preview, "MCP mcp:test-server/set_answer"
    assert_includes preview, '"answer":"42"'
  end

  # --- session glue: pinning, execution, resume guard --------------------------

  def build_config(answer_file, overrides = {})
    ServerConfig.new(
      **{
        server_id: "test-server",
        transport: :stdio,
        command: RbConfig.ruby,
        arguments: [SERVER_SCRIPT, answer_file],
        working_directory: @dir,
        env_allowlist: BASE_ENV_ALLOWLIST + FLAG_NAMES
      }.merge(overrides)
    )
  end

  def descriptor_for(snapshot, name, effect_class: :unknown_effects)
    entry = snapshot.entries.find { |candidate| candidate.name == name }
    Invocation.descriptor_for(entry, snapshot: snapshot, effect_class:)
  end

  def source_for(snapshot, supervisor:, names: %w[set_answer])
    descriptors = names.map { |name| descriptor_for(snapshot, name) }
    executor = lambda do |_context, descriptor, arguments|
      outcome = Invocation.call(
        descriptor, arguments, snapshot: snapshot, supervisor: supervisor
      )
      case outcome.status
      when :succeeded then outcome.observation.text
      when :denied
        raise Tamoz::Agent::ToolError,
              "MCP elicitation denied: #{outcome.denial.fetch("reason")}"
      when :interrupt
        raise Tamoz::Agent::ToolError,
              "MCP elicitation interrupt #{outcome.interrupt.fetch("effect_key")} " \
              "was not auto-answered"
      end
    rescue Tamoz::Mcp::ToolArgumentError => error
      raise Tamoz::Agent::ToolArgumentError, error.message
    rescue Tamoz::Mcp::ToolPolicyError, Tamoz::Mcp::UnavailableError,
           Tamoz::Mcp::AmbiguousOutcomeError => error
      raise Tamoz::Agent::ToolError, error.message
    end
    validator = lambda do |entry, arguments|
      begin
        MCP::Tool::InputSchema.new(entry.input_schema || {}).validate_arguments(arguments)
      rescue MCP::Tool::InputSchema::ValidationError
        raise Tamoz::Agent::ToolArgumentError,
              "the arguments for #{entry.id} are invalid"
      end
    end
    Source.new(catalogs: {snapshot.server_id => snapshot}, descriptors:, executor:, validator:)
  end

  def with_workspace
    Dir.mktmpdir("tamoz-session-mcp") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 5.0)
      )
      begin
        yield File.realpath(root), adapter
      ensure
        adapter.close
      end
    end
  end

  def answer_check(answer_file)
    [
      RbConfig.ruby,
      "-e",
      %q{abort("wrong") unless File.read(ARGV[0]).strip == "42"},
      answer_file
    ]
  end

  def mcp_session(root:, adapter:, source:, answer_file:, allow_changes: true)
    toolbox = Tamoz::Agent::Toolbox.new(
      root:, allow_changes:,
      checks: {"answer" => answer_check(answer_file)}
    )
    model = ScriptedModel.new(
      plan: [
        plan_for("read_file", {"path" => "broken.rb"}, id: "inspect"),
        {
          "goal" => "write the answer 42",
          "done_when" => ["the MCP server file holds 42"],
          "steps" => [
            {
              "id" => "mcp-write",
              "purpose" => "write the answer through the governed MCP call",
              "tool" => "mcp:test-server/set_answer",
              "arguments" => {"answer" => "42"},
              "verification" => "the receipt reports a succeeded effect"
            },
            {
              "id" => "check",
              "purpose" => "run the configured answer check",
              "tool" => "run_check",
              "arguments" => {"name" => "answer"},
              "verification" => "the check exits zero"
            }
          ]
        }
      ],
      review: [accepted_review, accepted_review],
      verify: [verified("The answer was written through the governed MCP call.", true)]
    )
    session = Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter, mcp: source)
    [session, model]
  end

  def test_session_pins_mcp_catalogs_and_executes_the_governed_call_through_the_journal
    with_workspace do |root, adapter|
      write_value(root, 40)
      answer_file = File.join(@dir, "answer.txt")
      config = build_config(answer_file)
      snapshot = Catalog.compile(config)
      supervisor = Supervisor.new(config)
      begin
        source = source_for(snapshot, supervisor:)
        session, model = mcp_session(root:, adapter:, source:, answer_file:)

        outcome = session.start(
          "Write the answer 42 to the configured MCP server file.",
          thread: "session.mcp",
          request_id: "request.1"
        )
        outcome = approve_all(session, outcome, thread: "session.mcp", request_id: "request.1")

        assert_equal :completed, outcome.status
        assert outcome.result.satisfied
        assert_equal "42", File.read(answer_file).strip
        assert_equal %i[plan plan review review verify].sort,
                     model.calls.map { |call| call.fetch(:stage) }.sort

        record = session.view(thread: "session.mcp").state.fetch(:session)
        assert_equal({"test-server" => snapshot.snapshot_digest}, record.fetch("mcp_catalogs"))

        receipt = session.view(thread: "session.mcp").effect_receipts.find do |entry|
          entry.fetch("operation") == "tool.mcp:test-server/set_answer"
        end
        refute_nil receipt, "the MCP call must be journaled like any reviewed tool call"
        assert_equal "succeeded", receipt.fetch("status")
        assert_equal "unsafe", receipt.fetch("safety"), "non-idempotent MCP effect is never read-only"

        intent = session.view(thread: "session.mcp").state.fetch(:effect_intents).find do |entry|
          entry.fetch("operation") == "tool.mcp:test-server/set_answer"
        end
        assert_equal "unsafe", intent.fetch("safety")
        refute intent.key?("before_state"), "an MCP effect is never filesystem-reconciled"
        assert_equal 0, supervisor.consecutive_failures
        assert adapter.integrity_check.fetch("ok")
      ensure
        supervisor.close
      end
    end
  end

  def test_session_resume_guard_accepts_the_identical_source_and_fails_closed_on_mismatch
    with_workspace do |root, adapter|
      write_value(root, 40)
      answer_file = File.join(@dir, "answer.txt")
      config = build_config(answer_file)
      snapshot = Catalog.compile(config)
      supervisor = Supervisor.new(config)
      begin
        source = source_for(snapshot, supervisor:)
        session, = mcp_session(root:, adapter:, source:, answer_file:)
        outcome = session.start(
          "Write the answer 42 to the configured MCP server file.",
          thread: "session.mcp.resume",
          request_id: "request.1"
        )
        outcome = approve_all(session, outcome, thread: "session.mcp.resume", request_id: "request.1")
        assert_equal :completed, outcome.status

        # A fresh session over the same durable thread with the identical source
        # resumes cleanly.
        source_again = source_for(snapshot, supervisor:)
        resumed = Tamoz::Agent::Session.new(
          model: ScriptedModel.new(plan: [], review: [], verify: []),
          toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks: {}),
          checkpointer: adapter,
          mcp: source_again
        )
        assert_nil resumed.verify_mcp_binding!(thread: "session.mcp.resume")

        # A changed catalog (the same server re-compiled with an extra tool) must
        # stop the resume typed before any node runs.
        ENV["MCP_TEST_SERVER_EXTRA_TOOLS"] = "1"
        changed = Catalog.compile(build_config(File.join(@dir, "other.txt")))
        changed_source = source_for(changed, supervisor:)
        other = Tamoz::Agent::Session.new(
          model: ScriptedModel.new(plan: [], review: [], verify: []),
          toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks: {}),
          checkpointer: adapter,
          mcp: changed_source
        )
        error = assert_raises(Tamoz::Agent::McpCatalogSnapshotUnavailableError) do
          other.continue(thread: "session.mcp.resume", request_id: "request.b")
        end
        assert_match(/was planned against MCP catalog digests/, error.message)
      ensure
        supervisor.close
      end
    end
  end

  def test_legacy_session_resumed_with_an_mcp_source_fails_closed
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [verified("Tamoz is awake.", true)]
      )
      plain = Tamoz::Agent::Session.new(
        model:,
        toolbox: Tamoz::Agent::Toolbox.new(root:),
        checkpointer: adapter
      )
      outcome = plain.start(
        "What does note.txt say?",
        thread: "session.mcp.legacy",
        request_id: "request.1"
      )
      assert_equal :completed, outcome.status
      record = plain.view(thread: "session.mcp.legacy").state.fetch(:session)
      assert_equal({}, record.fetch("mcp_catalogs"), "a session without an MCP source pins {}")

      answer_file = File.join(@dir, "answer.txt")
      snapshot = Catalog.compile(build_config(answer_file))
      supervisor = Supervisor.new(build_config(answer_file))
      begin
        source = source_for(snapshot, supervisor:)
        with_mcp = Tamoz::Agent::Session.new(
          model: ScriptedModel.new(plan: [], review: [], verify: []),
          toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks: {}),
          checkpointer: adapter,
          mcp: source
        )
        error = assert_raises(Tamoz::Agent::McpCatalogSnapshotUnavailableError) do
          with_mcp.continue(thread: "session.mcp.legacy", request_id: "request.b")
        end
        assert_match(/current source exposes/, error.message)
      ensure
        supervisor.close
      end
    end
  end

  def test_structural_review_rejects_bare_names_and_schema_invalid_arguments_without_io
    snapshot = fake_snapshot
    descriptor = fake_descriptor(snapshot, "echo")
    validator = lambda do |_entry, _arguments|
      raise Tamoz::Agent::ToolArgumentError, "the arguments are invalid"
    end
    source = Source.new(
      catalogs: {snapshot.server_id => snapshot}, descriptors: [descriptor],
      executor: ->(_, _, _) {}, validator:
    )
    toolbox = Tamoz::Agent::Toolbox.new(root: @dir)
    plan = Tamoz::Agent::Plan.parse(
      JSON.generate(
        "goal" => "g",
        "done_when" => ["d"],
        "steps" => [{"id" => "s", "purpose" => "p", "tool" => "mcp:test-server/echo",
                     "arguments" => {"value" => "x"}, "verification" => "v"}]
      )
    )
    capabilities = Tamoz::Agent::CapabilityBinding.build(toolbox:, mcp: source)
    issues = Tamoz::Agent::Deliberation.structural_issues(
      plan, phase: :discovery, allowed_tools: %w[read_file mcp:test-server/echo],
      toolbox:, capabilities:
    )
    assert_equal ["step \"s\" is invalid: the arguments are invalid"], issues

    bare_plan = Tamoz::Agent::Plan.parse(
      JSON.generate(
        "goal" => "g",
        "done_when" => ["d"],
        "steps" => [{"id" => "s", "purpose" => "p", "tool" => "echo",
                     "arguments" => {}, "verification" => "v"}]
      )
    )
    issues = Tamoz::Agent::Deliberation.structural_issues(
      bare_plan, phase: :discovery,
      allowed_tools: %w[read_file mcp:test-server/echo], toolbox:, capabilities:
    )
    assert_includes issues, 'step "s" uses unavailable tool "echo"'
  end

  # --- advB: exactly-once for the reissue path is the caller's journal ----------

  def test_effect_journal_is_the_exactly_once_guard_for_mcp_calls_and_reissue
    answer_file = File.join(@dir, "answer.txt")
    config = build_config(answer_file)
    snapshot = Catalog.compile(config)
    supervisor = Supervisor.new(config)
    wires = []
    factory = ->(sup) { CountingClient.new(sup, wires) }
    begin
      Dir.mktmpdir("tamoz-mcp-once") do |directory|
        adapter = Tamoz::SQLite::Adapter.new(
          path: File.join(directory, "tamoz.db"),
          limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 5.0)
        )
        app = base_definition.compile(checkpointer: adapter)
        request = app.durable_runner.deliver({}, thread: "thread.once", request_id: "request.setup")
        store = app.checkpointer
        set_answer = descriptor_for(snapshot, "set_answer")
        needs_input = descriptor_for(snapshot, "needs_input")

        write_perform = lambda do
          outcome = Invocation.call(
            set_answer, {"answer" => "42"}, snapshot:, supervisor:, client_factory: factory
          )
          raise "expected success" unless outcome.status == :succeeded

          outcome.observation.text
        end

        # Reissue path (advB): the originating call returns input_required and the
        # caller re-issues with the answer merged. The wire sees the originating
        # call plus one reissue — the journal holds exactly one effect entry, and
        # a second drive of the same step adds nothing.
        reissue_perform = lambda do
          first = Invocation.call(
            needs_input, {}, snapshot:, supervisor:, client_factory: factory
          )
          raise "expected interrupt" unless first.status == :interrupt

          reissued = Invocation.reissue(
            needs_input, {}, snapshot:, supervisor:,
            interrupt: first.interrupt, answers: {"value" => "42"}, client_factory: factory
          )
          raise "expected a second interrupt" unless reissued.status == :interrupt

          raise Tamoz::Agent::ToolError,
                "the server demands more input; the caller denies rather than fabricate an answer"
        end

        store.open_writer(
          thread_id: "thread.once", namespace: [], owner_id: "caller.one", ttl: store.writer_ttl
        ) do |writer|
          context = Tamoz::Context.new(
            run_id: "run.one", execution_id: request.execution_id, request_id: "request.one",
            task_id: "task.mcp-set", effects: writer.effects
          )
          first = Tamoz::Agent::EffectDispatcher.run(
            context:, operation: "tool.mcp:test-server/set_answer", safety: :unsafe,
            call_index: 0, request: {"tool" => "mcp:test-server/set_answer"},
            actor: "test.caller"
          ) { write_perform.call }
          assert_equal :succeeded, first.status

          # Re-drive the identical step: the journal returns the recorded receipt
          # and the perform (the wire call) is never invoked again.
          second = Tamoz::Agent::EffectDispatcher.run(
            context:, operation: "tool.mcp:test-server/set_answer", safety: :unsafe,
            call_index: 0, request: {"tool" => "mcp:test-server/set_answer"},
            actor: "test.caller"
          ) { write_perform.call }
          assert_equal :succeeded, second.status
          assert second.reused
          assert_equal first.effect_key, second.effect_key
        end

        set_answer_wires = wires.select { |entry| entry[:method] == "tools/call" && entry[:name] == "set_answer" }
        assert_equal 1, set_answer_wires.length, "one journal entry, one wire call"
        assert_equal "42", File.read(answer_file).strip

        # The reissue path: two wire lines (originating call + reissue) for one
        # journal entry, then the duplicate drive is a no-op.
        store.open_writer(
          thread_id: "thread.once", namespace: [], owner_id: "caller.two", ttl: store.writer_ttl
        ) do |writer|
          context = Tamoz::Context.new(
            run_id: "run.two", execution_id: request.execution_id, request_id: "request.two",
            task_id: "task.mcp-reissue", effects: writer.effects
          )
          first = Tamoz::Agent::EffectDispatcher.run(
            context:, operation: "tool.mcp:test-server/needs_input", safety: :unsafe,
            call_index: 0, request: {"tool" => "mcp:test-server/needs_input"},
            actor: "test.caller"
          ) { reissue_perform.call }
          assert_equal :failed, first.status
          refute first.reused

          before = wires.length
          second = Tamoz::Agent::EffectDispatcher.run(
            context:, operation: "tool.mcp:test-server/needs_input", safety: :unsafe,
            call_index: 0, request: {"tool" => "mcp:test-server/needs_input"},
            actor: "test.caller"
          ) { reissue_perform.call }
          assert_equal :failed, second.status
          assert second.reused
          assert_equal first.effect_key, second.effect_key
          assert_equal before, wires.length,
                       "re-issuing the same interrupt+answer a second time adds no wire round"
        end

        needs_input_wires = wires.select do |entry|
          entry[:method] == "tools/call" && entry[:name] == "needs_input"
        end
        assert_equal 2, needs_input_wires.length, "one originating call + one reissue"
        tools_call_wires = wires.select { |entry| entry[:method] == "tools/call" }
        assert_equal 3, tools_call_wires.length,
                     "one set_answer, one needs_input call, one reissue — once each"
      ensure
        adapter&.close
      end
    ensure
      supervisor.close
    end
  end

  # --- planning surface (P10 §3: the MCP names must reach the planner) ---------

  def test_the_planning_prompt_renders_the_mcp_surface
    toolbox = Tamoz::Agent::Toolbox.new(root: @dir)
    allowed = toolbox.names + ["mcp:test-server/set_answer"]
    prompt = Tamoz::Agent::Deliberation.planning_prompt(
      "task", :discovery, allowed, [], [], {}, toolbox:,
      mcp_tools: {"mcp:test-server/set_answer" => "Set the answer variable"}
    )

    assert_includes prompt, "mcp:test-server/set_answer"
    assert_includes prompt, "Set the answer variable"
    assert_includes prompt, "read_file"
  end

  def test_the_planning_prompt_filters_mcp_tools_to_the_allowed_set
    toolbox = Tamoz::Agent::Toolbox.new(root: @dir)
    prompt = Tamoz::Agent::Deliberation.planning_prompt(
      "task", :discovery, toolbox.names, [], [], {}, toolbox:,
      mcp_tools: {"mcp:test-server/set_answer" => "Set the answer variable"}
    )

    refute_includes prompt, "mcp:test-server/set_answer"
  end

  def test_the_planning_prompt_without_mcp_is_byte_identical
    toolbox = Tamoz::Agent::Toolbox.new(root: @dir)
    base = Tamoz::Agent::Deliberation.planning_prompt(
      "task", :read_only, toolbox.names, [], [], {}, toolbox:
    )

    assert_equal base, Tamoz::Agent::Deliberation.planning_prompt(
      "task", :read_only, toolbox.names, [], [], {}, toolbox:, mcp_tools: {}
    )
    refute_includes base, "mcp:"
  end

  def test_a_session_with_mcp_renders_the_stripped_mcp_surface_in_the_plan_prompt
    snapshot = fake_snapshot(descriptions: {"set_answer" => "Set the answer\x00 value"})
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "Tamoz is awake.\n")
      source = Source.new(
        catalogs: {snapshot.server_id => snapshot},
        descriptors: [fake_descriptor(snapshot, "set_answer")],
        executor: ->(_, _, _) { "answer file written" }
      )
      model = ScriptedModel.new(
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [verified("Tamoz is awake.", true)]
      )
      session = Tamoz::Agent::Session.new(
        model:,
        toolbox: Tamoz::Agent::Toolbox.new(root:),
        checkpointer: adapter,
        mcp: source
      )
      outcome = session.start(
        "What does note.txt say?",
        thread: "planning.surface",
        request_id: "request.1"
      )
      assert_equal :completed, outcome.status

      plan_call = model.calls.find { |call| call[:stage] == :plan }
      assert plan_call, "a plan call must have happened"
      assert_includes plan_call[:prompt], "mcp:test-server/set_answer"
      assert_includes plan_call[:prompt], "Set the answer value"
      refute_includes plan_call[:prompt], "\x00"
    end
  end

  private

  def write_value(root, value)
    File.write(
      File.join(root, "broken.rb"),
      "module Broken\n  def self.answer = #{value}\nend\n"
    )
  end

  def plan_for(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {
          "id" => id,
          "purpose" => "gather evidence",
          "tool" => tool,
          "arguments" => arguments,
          "verification" => "the output is present"
        }
      ]
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "sound"}
  end

  def verified(answer, satisfied)
    {
      "answer" => answer,
      "satisfied" => satisfied,
      "evidence" => ["controller-owned deterministic evidence"]
    }
  end

  def approve_all(session, outcome, thread:, request_id:)
    current = outcome
    index = 0
    while current.status == :paused && index < 8
      index += 1
      task_id = session.view(thread:).interrupts.first.task_id
      current = session.resume(
        {task_id => {0 => true}},
        thread:,
        request_id: "#{request_id}.#{index}"
      )
    end
    current
  end

  def base_definition
    Tamoz.graph(name: "agent-mcp-base", version: "1") do
      state :ready, default: false
      node(:finish, implementation_name: "agent.mcp.finish", version: "1") do |_state, _context|
        {ready: true}
      end
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end
end
