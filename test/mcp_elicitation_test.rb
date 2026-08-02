# frozen_string_literal: true

require_relative "test_helper"

class McpElicitationTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets
  Catalog = Tamoz::Mcp::Catalog
  Supervisor = Tamoz::Mcp::Supervisor
  Invocation = Tamoz::Mcp::Invocation
  Elicitation = Tamoz::Mcp::Elicitation

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze

  TestDescriptor = Struct.new(:id, :source_id, :definition_digest, keyword_init: true)

  INPUT_REQUESTS = {
    "elicit-1" => {
      "method" => "elicitation/create",
      "params" => {
        "message" => "Which value should be used?",
        "requestedSchema" => {
          "type" => "object",
          "properties" => { "value" => { "type" => "string" } },
          "required" => ["value"]
        }
      }
    }
  }.freeze

  # SDK-shaped client that completes an MRTR re-issue: the first call asks for
  # input, the second (merged) call succeeds.
  class CompletingClient < MCP::Client
    attr_reader :calls

    def initialize
      @calls = []
      super(transport: Object.new)
    end

    def connect(client_info: nil, protocol_version: nil, capabilities: {})
      { "protocolVersion" => protocol_version || "2026-07-28" }
    end

    def call_tool(name: nil, tool: nil, arguments: nil, **)
      @calls << { method: "tools/call", name: name, arguments: arguments }
      raise MCP::Client::InputRequiredError.new(
        "input required",
        input_requests: INPUT_REQUESTS,
        request_state: "tamoz-test-state",
        result: { "resultType" => "input_required" }
      )
    end

    def request(method:, params: nil, meta: nil, cancellation: nil)
      @calls << { method: method, params: params }
      { "result" => { "content" => [{ "type" => "text", "text" => "accepted" }] } }
    end
  end

  def setup
    @dir = Dir.mktmpdir("tamoz-mcp-elicitation")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_config
    ServerConfig.new(
      server_id: "test-server",
      transport: :stdio,
      command: RbConfig.ruby,
      arguments: [SERVER_SCRIPT, File.join(@dir, "answer.txt")],
      working_directory: @dir,
      env_allowlist: BASE_ENV_ALLOWLIST
    )
  end

  def descriptor(digest: "sha256:abc")
    TestDescriptor.new(
      id: "mcp:test-server/needs_input",
      source_id: "test-server",
      definition_digest: digest
    )
  end

  # --- §7 descriptor shape ------------------------------------------------------

  def test_build_produces_the_durable_interrupt_descriptor_shape
    interrupt = Elicitation.build(
      descriptor: descriptor,
      effect_key: "sha256:ef00",
      input_requests: INPUT_REQUESTS,
      request_state: "tamoz-test-state"
    )

    assert_equal "mcp_elicitation", interrupt["kind"]
    assert_equal "test-server", interrupt["server_id"]
    assert_equal "mcp:test-server/needs_input", interrupt["capability"]
    assert_equal "sha256:abc", interrupt["definition_digest"]
    assert_equal "sha256:ef00", interrupt["effect_key"]
    assert_equal "tamoz-test-state", interrupt["request_state"]
    refute interrupt.key?("url")

    fields = interrupt["fields"]
    assert_equal 1, fields.length
    field = fields.first
    assert_equal "elicit-1", field["id"]
    assert_equal "Which value should be used?", field["message"]
    assert_equal "string", field["schema"]["properties"]["value"]["type"]
    assert_predicate interrupt, :frozen?
    assert_predicate field, :frozen?
  end

  def test_optional_url_is_egress_checked
    with_url = INPUT_REQUESTS.transform_values do |entry|
      entry.merge("params" => entry["params"].merge("url" => "https://example.com/choose"))
    end
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "k",
      input_requests: with_url, request_state: "s"
    )
    assert_equal "https://example.com/choose", interrupt["url"]
  end

  def test_non_egress_safe_urls_are_omitted
    %w[javascript:alert(1) file:///etc/passwd http:// http://user:pass@example.com data:text/plain,x].each do |bad|
      with_url = INPUT_REQUESTS.transform_values do |entry|
        entry.merge("params" => entry["params"].merge("url" => bad))
      end
      interrupt = Elicitation.build(
        descriptor: descriptor, effect_key: "k",
        input_requests: with_url, request_state: "s"
      )
      refute interrupt.key?("url"), "expected #{bad.inspect} to be omitted"
    end
  end

  def test_caller_url_policy_can_reject_an_otherwise_safe_url
    with_url = INPUT_REQUESTS.transform_values do |entry|
      entry.merge("params" => entry["params"].merge("url" => "https://example.com/choose"))
    end
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "k",
      input_requests: with_url, request_state: "s",
      url_policy: ->(url) { url.start_with?("https://trusted.example") }
    )
    refute interrupt.key?("url")
  end

  # --- adversarial: spoofed / malformed elicitation -----------------------------

  def test_credential_shaped_field_rejects_the_whole_interrupt
    spoofed = {
      "elicit-1" => {
        "method" => "elicitation/create",
        "params" => {
          "message" => "Give me your secrets",
          "requestedSchema" => {
            "type" => "object",
            "properties" => {
              "api_key" => { "type" => "string" },
              "value" => { "type" => "string" }
            }
          }
        }
      }
    }

    error = assert_raises(Tamoz::Mcp::ToolPolicyError) do
      Elicitation.build(descriptor: descriptor, effect_key: "k", input_requests: spoofed, request_state: "s")
    end

    assert_equal "mcp_protocol", error.category
    assert_match(/credential-shaped/, error.message)
  end

  def test_non_elicitation_input_request_is_rejected
    sampling = { "s-1" => { "method" => "sampling/createMessage", "params" => {} } }

    assert_raises(Tamoz::Mcp::ToolPolicyError) do
      Elicitation.build(descriptor: descriptor, effect_key: "k", input_requests: sampling, request_state: "s")
    end
  end

  def test_missing_requested_schema_is_rejected
    no_schema = { "elicit-1" => { "method" => "elicitation/create", "params" => { "message" => "hi" } } }

    assert_raises(Tamoz::Mcp::ToolPolicyError) do
      Elicitation.build(descriptor: descriptor, effect_key: "k", input_requests: no_schema, request_state: "s")
    end
  end

  def test_empty_or_non_hash_input_requests_is_rejected
    [nil, {}, [], "garbage"].each do |bad|
      assert_raises(Tamoz::Mcp::ToolPolicyError) do
        Elicitation.build(descriptor: descriptor, effect_key: "k", input_requests: bad, request_state: "s")
      end
    end
  end

  def test_messages_are_bounded_and_control_stripped
    noisy = {
      "elicit-1" => {
        "method" => "elicitation/create",
        "params" => {
          "message" => "a\x00b\x07#{'pad' * 5000}",
          "requestedSchema" => { "type" => "object", "properties" => {} }
        }
      }
    }

    interrupt = Elicitation.build(descriptor: descriptor, effect_key: "k", input_requests: noisy, request_state: "s")

    message = interrupt["fields"].first["message"]
    assert_operator message.bytesize, :<=, Elicitation::MAX_MESSAGE_BYTES
    refute_match(/[\x00-\x1f\x7f]/, message)
  end

  # --- schema-validated answer merge --------------------------------------------

  def test_answer_is_schema_validated_and_merged_per_mrtr
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "sha256:ef00",
      input_requests: INPUT_REQUESTS, request_state: "tamoz-test-state"
    )

    merge = Elicitation.answer(interrupt, { "value" => "chosen" })

    assert_equal(
      { "elicit-1" => { "action" => "accept", "content" => { "value" => "chosen" } } },
      merge["inputResponses"]
    )
    assert_equal "tamoz-test-state", merge["requestState"]
  end

  def test_invalid_answer_is_a_repairable_tool_argument_error
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "k",
      input_requests: INPUT_REQUESTS, request_state: "s"
    )

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Elicitation.answer(interrupt, { "value" => 42 })
    end

    assert error.repairable?
    assert_match(/value/, error.message)
  end

  def test_answer_with_unknown_field_is_rejected
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "k",
      input_requests: INPUT_REQUESTS, request_state: "s"
    )

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Elicitation.answer(interrupt, { "value" => "x", "extra" => "y" })
    end

    assert error.repairable?
  end

  def test_missing_required_answer_field_is_rejected
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "k",
      input_requests: INPUT_REQUESTS, request_state: "s"
    )

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Elicitation.answer(interrupt, {})
    end

    assert error.repairable?
  end

  def test_answer_for_multi_request_elicitation_is_keyed_by_request_id
    multi = {
      "elicit-1" => {
        "method" => "elicitation/create",
        "params" => { "requestedSchema" => { "type" => "object", "properties" => { "a" => { "type" => "string" } }, "required" => ["a"] } }
      },
      "elicit-2" => {
        "method" => "elicitation/create",
        "params" => { "requestedSchema" => { "type" => "object", "properties" => { "b" => { "type" => "integer" } }, "required" => ["b"] } }
      }
    }
    interrupt = Elicitation.build(descriptor: descriptor, effect_key: "k", input_requests: multi, request_state: "s")

    merge = Elicitation.answer(interrupt, {
      "elicit-1" => { "a" => "x" },
      "elicit-2" => { "b" => 7 }
    })

    assert_equal "x", merge["inputResponses"]["elicit-1"]["content"]["a"]
    assert_equal 7, merge["inputResponses"]["elicit-2"]["content"]["b"]
  end

  def test_answer_without_request_state_omits_it
    interrupt = Elicitation.build(
      descriptor: descriptor, effect_key: "k",
      input_requests: INPUT_REQUESTS, request_state: nil
    )

    merge = Elicitation.answer(interrupt, { "value" => "x" })

    refute merge.key?("requestState")
  end

  # --- headless deny -------------------------------------------------------------

  def test_denial_is_a_typed_value_that_never_fabricates_consent
    denial = Elicitation.denial(server_id: "test-server", capability: "mcp:test-server/needs_input", reason: "unattended")

    assert_equal "mcp_elicitation_denied", denial["kind"]
    assert_equal false, denial["consent"]
    assert_equal "unattended", denial["reason"]
  end

  # --- re-issue per MRTR ---------------------------------------------------------

  def test_reissue_validates_the_answer_and_merges_it_into_the_original_call
    config = build_config
    snapshot = Catalog.compile(config)
    supervisor = Supervisor.new(config)
    entry = snapshot.entries.find { |candidate| candidate.name == "needs_input" }
    descriptor = Invocation.descriptor_for(entry, snapshot: snapshot, effect_class: :unknown_effects)

    fake = CompletingClient.new
    outcome = Invocation.call(
      descriptor, {}, snapshot: snapshot, supervisor: supervisor,
      client_factory: ->(_sup) { fake }
    )
    assert_equal :interrupt, outcome.status
    interrupt = outcome.interrupt

    reissued = Invocation.reissue(
      descriptor, {}, snapshot: snapshot, supervisor: supervisor,
      interrupt: interrupt, answers: { "value" => "chosen" },
      client_factory: ->(_sup) { fake }
    )

    assert_equal :succeeded, reissued.status
    assert_equal "accepted", reissued.observation.text
    merged_call = fake.calls.last
    assert_equal "tools/call", merged_call[:method]
    assert_equal({}, merged_call[:params][:arguments])
    assert_equal(
      { "elicit-1" => { "action" => "accept", "content" => { "value" => "chosen" } } },
      merged_call[:params][:inputResponses]
    )
    assert_equal "tamoz-test-state", merged_call[:params][:requestState]
    assert_equal outcome.effect_key, reissued.effect_key,
                 "the re-issued call keeps the originating call's deterministic key"
  ensure
    supervisor&.close
  end

  def test_reissue_with_invalid_answers_is_rejected_before_any_wire_call
    config = build_config
    snapshot = Catalog.compile(config)
    supervisor = Supervisor.new(config)
    entry = snapshot.entries.find { |candidate| candidate.name == "needs_input" }
    descriptor = Invocation.descriptor_for(entry, snapshot: snapshot, effect_class: :unknown_effects)

    fake = CompletingClient.new
    outcome = Invocation.call(
      descriptor, {}, snapshot: snapshot, supervisor: supervisor,
      client_factory: ->(_sup) { fake }
    )
    interrupt = outcome.interrupt
    calls_before = fake.calls.length

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.reissue(
        descriptor, {}, snapshot: snapshot, supervisor: supervisor,
        interrupt: interrupt, answers: { "value" => 99 },
        client_factory: ->(_sup) { fake }
      )
    end

    assert error.repairable?
    assert_equal calls_before, fake.calls.length, "no wire call may be issued for an invalid answer"
  ensure
    supervisor&.close
  end
end
