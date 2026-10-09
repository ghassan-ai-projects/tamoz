# frozen_string_literal: true

require_relative "test_helper"
require_relative 'support/read_note_plan'
require "tamoz/mcp/websearch"

class WebsearchInvocationTest < Minitest::Test
  include ReadNotePlan

  ServerConfig = Tamoz::Mcp::ServerConfig
  Catalog = Tamoz::Mcp::Catalog
  Supervisor = Tamoz::Mcp::Supervisor
  Invocation = Tamoz::Mcp::Invocation
  Source = Tamoz::Agent::McpCapabilitySource

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  ADAPTER_SCRIPT = ROOT.join("script", "websearch_adapter").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze
  WEBSEARCH_FLAGS = %w[
    TAMOZ_WEBSEARCH_GRANT TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_FIXTURE_MODE
    TAMOZ_WEBSEARCH_FIXTURE_OVERSIZE TAMOZ_WEBSEARCH_FIXTURE_ERROR TAMOZ_WEBSEARCH_PROVIDER
  ].freeze

  def setup
    @dir = Dir.mktmpdir("tamoz-websearch-invocation")
    @saved = ENV.to_h.slice(*WEBSEARCH_FLAGS)
  end

  # A session-driving scripted model: `plans` is the plan queue (each attempt
  # consumes one), `reviews` the semantic-review queue, `verification` the
  # single verify document. Returns JSON strings; records every stage.
  class ScriptedSessionModel
    attr_reader :calls

    def initialize(plans:, reviews:, verification:)
      @plans = plans
      @reviews = Array.new(reviews) { {"decision" => "accept", "issues" => [], "rationale" => "sound"} }
      @verification = verification
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << stage
      queue = stage == :plan ? @plans : (stage == :review ? @reviews : [@verification])
      raise "scripted model queue exhausted for #{stage}" if queue.empty?

      JSON.generate(stage == :verify ? queue.first : queue.shift)
    end
  end

  # The durable session coerces model output with `String(...)`, so the raw
  # string JSON passes through untouched.
  class SessionJSONWrapper
    def initialize(inner)
      @inner = inner
    end

    def calls = @inner.calls

    def generate(stage:, system:, prompt:)
      response = @inner.generate(stage:, system:, prompt:)
      response.is_a?(String) ? response : JSON.generate(response)
    end
  end

  def approve_mcp_session_like(session, outcome, thread:)
    current = outcome
    index = 0
    while current.status == :paused && index < 8
      index += 1
      task_id = session.view(thread:).interrupts.first.task_id
      current = session.resume(
        {task_id => {0 => true}},
        thread:,
        request_id: "request.1.#{index}"
      )
    end
    current
  end

  def teardown
    WEBSEARCH_FLAGS.each { |name| ENV.delete(name) }
    @saved.each { |name, value| ENV[name] = value }
    FileUtils.remove_entry(@dir)
  end

  def egress
    {
      "allowlisted_hosts" => ["api.search.example"],
      "schemes" => ["https"],
      "deny_private_ranges" => true,
      "max_request_bytes" => 2048,
      "max_response_bytes" => 4096,
      "connect_timeout_s" => 10,
      "redirect_max_hops" => 3,
      "circuit" => {"threshold" => 3, "scope_type" => "egress", "budget_breach" => true},
      "credential_refs" => ["TAMOZ_BRAVE_API_KEY"]
    }
  end

  def self.snapshots = @snapshots ||= {}

  def compiled(config)
    self.class.snapshots[[config.server_id, config.arguments]] ||= Catalog.compile(config)
  end

  def fixture_config(server_id: "websearch", extra_env: [])
    ServerConfig.new(
      server_id:,
      transport: :stdio,
      command: RbConfig.ruby,
      arguments: [SERVER_SCRIPT],
      working_directory: @dir,
      env_allowlist: BASE_ENV_ALLOWLIST + WEBSEARCH_FLAGS + extra_env,
      budgets: Tamoz::Mcp::Websearch.egress_budgets(egress)
    )
  end

  def granted
    ENV["TAMOZ_WEBSEARCH_GRANT"] = "1"
    ENV["TAMOZ_WEBSEARCH_EGRESS"] = JSON.generate(egress)
  end

  def search_descriptor(snapshot)
    Invocation.descriptor_for(
      snapshot.entries.find { |entry| entry.name == "search" },
      snapshot:,
      effect_class: :read_only
    )
  end

  def call_search(supervisor:, snapshot:, arguments: {"query" => "the answer"})
    Invocation.call(
      search_descriptor(snapshot), arguments,
      snapshot:, supervisor:
    )
  end

  def test_no_provider_config_means_no_websearch_surface
    # A capability source built without a websearch descriptor exposes no
    # websearch name; a bare config admits nothing.
    config = fixture_config(server_id: "other-server")
    snapshot = compiled(config)
    echo = Invocation.descriptor_for(
      snapshot.entries.find { |entry| entry.name == "echo_constant" },
      snapshot:,
      effect_class: :read_only
    )
    source = Source.new(catalogs: {snapshot.server_id => snapshot}, descriptors: [echo], executor: ->(*) { "" })
    refute source.name?("mcp:websearch/search")
    refute source.name?("websearch")
    assert_empty source.names.grep(/websearch/)
  end

  def test_search_refused_without_operator_grant_but_served_with_it
    ENV.delete("TAMOZ_WEBSEARCH_GRANT")
    ENV["TAMOZ_WEBSEARCH_EGRESS"] = JSON.generate(egress)
    config = fixture_config
    snapshot = compiled(config)
    supervisor = Supervisor.new(config)
    begin
      error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
        call_search(supervisor:, snapshot:)
      end
      assert_match(/mcp_remote_error/, error.message)
    ensure
      supervisor.close
    end

    granted
    supervisor = Supervisor.new(config)
    begin
      outcome = call_search(supervisor:, snapshot:)
      assert_equal :succeeded, outcome.status
      assert outcome.observation.text.include?("42")
    ensure
      supervisor.close
    end
  end

  def test_real_adapter_enforces_the_operator_gate
    require "tamoz/mcp/websearch"
    adapter_config = ServerConfig.new(
      server_id: "websearch",
      transport: :stdio,
      command: RbConfig.ruby,
      arguments: [ADAPTER_SCRIPT],
      working_directory: @dir,
      env_allowlist: BASE_ENV_ALLOWLIST + %w[TAMOZ_WEBSEARCH_GRANT TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_PROVIDER]
    )
    snapshot = compiled(adapter_config)
    assert snapshot.entries.map(&:name).include?("search")

    supervisor = Supervisor.new(adapter_config)
    begin
      error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
        call_search(supervisor:, snapshot:)
      end
      assert_match(/mcp_remote_error/, error.message)
    ensure
      supervisor.close
    end

    # With the grant + egress + a fixture provider the adapter's search is
    # deterministic and dial-free.
    web = File.join(@dir, "web.json")
    File.write(web, JSON.generate("pages" => [{"url" => "https://answers.example/42", "title" => "The answer",
                                               "text" => "The configured answer is 42."}]))
    ENV["TAMOZ_WEBSEARCH_GRANT"] = "1"
    ENV["TAMOZ_WEBSEARCH_EGRESS"] = JSON.generate(egress)
    ENV["TAMOZ_WEBSEARCH_PROVIDER"] = JSON.generate("search" => "fixture", "reader" => "fixture", "web" => web)
    supervisor = Supervisor.new(adapter_config)
    begin
      outcome = call_search(supervisor:, snapshot:, arguments: {"query" => "the configured answer"})
      assert_equal :succeeded, outcome.status
      assert outcome.observation.text.include?("42")
      entry = snapshot.entries.find { |candidate| candidate.name == "read_page" }
      read = Invocation.descriptor_for(entry, snapshot:, effect_class: :read_only)
      page = Invocation.call(read, {"url" => "https://answers.example/42"}, snapshot:, supervisor:)
      assert_equal :succeeded, page.status
      assert page.observation.text.include?("The configured answer is 42.")
    ensure
      supervisor.close
    end
  end

  # read_page takes only a URL this process's searches returned; read_url leaves the URL's provenance to Tamoz.
  def test_real_adapter_reads_an_unsearched_page_only_through_read_url
    require "tamoz/mcp/websearch"
    web = File.join(@dir, "web.json")
    File.write(web, JSON.generate("pages" => [{"url" => "https://answers.example/42", "title" => "The answer",
                                               "text" => "The configured answer is 42."}]))
    ENV["TAMOZ_WEBSEARCH_GRANT"] = "1"
    ENV["TAMOZ_WEBSEARCH_EGRESS"] = JSON.generate(egress)
    ENV["TAMOZ_WEBSEARCH_PROVIDER"] = JSON.generate("search" => "fixture", "reader" => "fixture", "web" => web)
    config = ServerConfig.new(
      server_id: "websearch", transport: :stdio, command: RbConfig.ruby, arguments: [ADAPTER_SCRIPT],
      working_directory: @dir,
      env_allowlist: BASE_ENV_ALLOWLIST + %w[TAMOZ_WEBSEARCH_GRANT TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_PROVIDER]
    )
    snapshot = compiled(config)
    reader = ->(name) { Invocation.descriptor_for(snapshot.entries.find { |entry| entry.name == name }, snapshot:) }
    supervisor = Supervisor.new(config)
    begin
      arguments = {"url" => "https://answers.example/42"}
      assert_raises(Tamoz::Mcp::ToolArgumentError) { Invocation.call(reader.call("read_page"), arguments, snapshot:, supervisor:) }
      page = Invocation.call(reader.call("read_url"), arguments, snapshot:, supervisor:)
      assert page.observation.text.include?("The configured answer is 42.")
    ensure
      supervisor.close
    end
  end

  def test_search_success_is_attributed_bounded_and_deterministic
    granted
    config = fixture_config
    snapshot = compiled(config)
    supervisor = Supervisor.new(config)
    begin
      outcome = call_search(supervisor:, snapshot:)
      assert_equal :succeeded, outcome.status
      assert outcome.observation.attributed?
      assert outcome.observation.text.include?("42")
      assert_operator outcome.observation.text.bytesize, :<=, egress.fetch("max_response_bytes")
    ensure
      supervisor.close
    end
  end

  def test_provider_declared_error_is_typed_repairable
    granted
    ENV["TAMOZ_WEBSEARCH_FIXTURE_ERROR"] = "1"
    config = fixture_config
    snapshot = compiled(config)
    supervisor = Supervisor.new(config)
    begin
      error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
        call_search(supervisor:, snapshot:)
      end
      assert_match(/mcp_remote_error/, error.message)
      assert error.repairable?
    ensure
      supervisor.close
    end
  end

  def test_oversize_response_is_bounded_and_opens_the_budget_condition
    granted
    ENV["TAMOZ_WEBSEARCH_FIXTURE_OVERSIZE"] = "1"
    config = fixture_config
    snapshot = compiled(config)
    circuit = Tamoz::Mcp::Websearch::EgressCircuit.new(
      threshold: 3, scope_id: "egress:websearch", budget_breach: true
    )
    supervisor = Supervisor.new(config, circuit_store: circuit)
    begin
      outcome = call_search(supervisor:, snapshot:)
      assert_equal :succeeded, outcome.status
      assert outcome.observation.truncated
      assert_operator outcome.observation.text.bytesize, :<=, egress.fetch("max_response_bytes")
      supervisor.record_failure(
        kind: :budget_breach,
        context: {"tool_name" => "search", "reason" => "max_response_bytes"}
      )
      assert circuit.open?, "a budget breach must open the egress circuit"
    ensure
      supervisor.close
    end
  end

  def test_credential_shaped_query_is_rejected_with_no_call_and_no_sink
    granted
    config = fixture_config
    snapshot = compiled(config)
    circuit = Tamoz::Mcp::Websearch::EgressCircuit.new(
      threshold: 3, scope_id: "egress:websearch", budget_breach: true
    )
    supervisor = Supervisor.new(config, circuit_store: circuit)
    source = Source.new(
      catalogs: {snapshot.server_id => snapshot},
      descriptors: [search_descriptor(snapshot)],
      executor: lambda do |_context, descriptor, arguments|
        outcome = Invocation.call(descriptor, arguments, snapshot:, supervisor:)
        outcome.observation.text
      end,
      validator: lambda do |descriptor, arguments|
        query = arguments["query"]
        raise Tamoz::Agent::ToolArgumentError,
              "the websearch query argument is credential-shaped and was rejected before any call" \
          if Tamoz::Mcp::Websearch.credential_shaped_query?(query)
      end
    )
    credential = "token=AKIAIOSFODNN7EXAMPLE"
    begin
      error = assert_raises(Tamoz::Agent::ToolArgumentError) do
        source.validate("mcp:websearch/search", {"query" => credential})
      end
      assert_match(/credential-shaped/, error.message)
      refute_match(/#{Regexp.escape(credential)}/, error.message)
      assert_nil supervisor.pid, "no call is issued, so nothing is spawned"
      # The value must appear in no sink: the session record is written only by
      # real runs, so the sweep proves the rejected value never reached one.
      assert_empty Dir.glob(File.join(@dir, "**", "*.sqlite3"))
    ensure
      supervisor.close
    end
  end

  def test_journal_invocation_arguments_carry_no_credential_value
    granted
    config = fixture_config
    snapshot = compiled(config)
    supervisor = Supervisor.new(config)
    begin
      outcome = call_search(supervisor:, snapshot:)
      assert_equal :succeeded, outcome.status
      payload = JSON.generate(outcome.observation.to_h)
      refute_includes payload, "sk-"
      refute_includes payload, "AKIA"
      refute_includes payload, "token="
    ensure
      supervisor.close
    end
  end

  def test_session_rejects_credential_shaped_query_and_the_value_reaches_no_sink
    granted
    require "tamoz/sqlite"
    credential = "token=AKIAIOSFODNN7EXAMPLE"
    dir = Dir.mktmpdir("tamoz-websearch-w6")
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    File.write(File.join(workspace, "note.txt"), "Tamoz is awake.\n")
    config = fixture_config
    snapshot = compiled(config)
    circuit = Tamoz::Mcp::Websearch::EgressCircuit.new(
      threshold: 3, scope_id: "egress:websearch", budget_breach: true
    )
    supervisor = Supervisor.new(config, circuit_store: circuit)
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, "session.sqlite3"))
    model = ScriptedSessionModel.new(
      plans: [
        read_plan,
        {"goal" => "search", "done_when" => ["answer"], "steps" => [
          {"id" => "bad", "purpose" => "search", "tool" => "mcp:websearch/search",
           "arguments" => {"query" => credential}, "verification" => "out"}
        ]},
        {"goal" => "search", "done_when" => ["answer"], "steps" => [
          {"id" => "s2", "purpose" => "search", "tool" => "mcp:websearch/search",
           "arguments" => {"query" => "the answer"}, "verification" => "out"}
        ]}
      ],
      reviews: 2,
      verification: {"answer" => "42", "satisfied" => true, "evidence" => ["search result"]}
    )
    begin
      source = Source.new(
        catalogs: {snapshot.server_id => snapshot},
        descriptors: [search_descriptor(snapshot)],
        executor: lambda do |_context, descriptor, arguments|
          outcome = Invocation.call(descriptor, arguments, snapshot:, supervisor:)
          "remote content from server websearch: " \
            "#{Tamoz::Mcp::Websearch.sanitize_result(outcome.observation.text)}"
        end,
        validator: lambda do |descriptor, arguments|
          query = arguments["query"]
          raise Tamoz::Agent::ToolArgumentError,
                "the websearch query argument is credential-shaped and was rejected before any call" \
            if query.is_a?(String) && Tamoz::Mcp::Websearch.credential_shaped_query?(query)
        end
      )
      toolbox = Tamoz::Agent::Toolbox.new(
        root: workspace, allow_changes: true, checks: {},
        allowed_tools: %w[read_file]
      )
      session = Tamoz::Agent::Session.new(
        model: SessionJSONWrapper.new(model), toolbox:, checkpointer: adapter, mcp: source
      )
      outcome = session.start("Find the answer.", thread: "w6", request_id: "request.1")
      outcome = approve_mcp_session_like(session, outcome, thread: "w6")
      assert_equal :completed, outcome.status, "the clean replan must complete"
      assert_equal %i[plan review plan plan review verify], model.calls

      blob = File.binread(File.join(dir, "session.sqlite3"))
      refute_includes blob, credential, "the credential value must not reach the session record"
      state = session.view(thread: "w6").state
      assert_equal 2, state.fetch(:plan_versions).length, "only the clean plans are committed"
      refute state.fetch(:plan_versions).any? { |p| p.to_s.include?("AKIA") }
      assert state.fetch(:observations).none? { |o| o.to_s.include?("AKIA") }
    ensure
      adapter.close
      supervisor.close
      FileUtils.remove_entry(dir)
    end
  end

  def test_credential_shaped_result_is_stripped_never_fillable
    text = "The answer is 42. OPENAI_API_KEY=sk-fixture-leaked-value " \
           "field api_token: sk-fixture-leaked-value"
    sanitized = Tamoz::Mcp::Websearch.sanitize_result(text)
    refute_includes sanitized, "sk-fixture-leaked-value"
    refute_includes sanitized, "OPENAI_API_KEY="
    assert_includes sanitized, "42"
    assert_includes sanitized, "stripped"
  end

  def test_fixture_run_uses_the_egress_declaration_budgets
    granted
    config = fixture_config
    assert_equal 4096, config.budgets.max_output_bytes
    assert_equal 10.0, config.budgets.connect_timeout
  end
end
