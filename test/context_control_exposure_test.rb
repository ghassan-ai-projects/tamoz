# frozen_string_literal: true

require_relative 'test_helper'
require 'delegate'
require 'securerandom'

# Phase 3 wave B: the typed session context controls are exposed
# identically-in-meaning on both surfaces — the channel gateway's command
# table and the durable CLI — over the landed SessionContextControls
# semantics. The gateway half drives real serve_once passes against a real
# SQLite runtime database; the CLI half drives the real argv dispatch.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class ContextControlExposureTest < Minitest::Test
  Comms = Tamoz::Comms
  Records = Tamoz::Agent::SessionRecords

  SURFACE_ID = 'telegram-ops'
  BOT_ID = 7_463_512_990
  CONVERSATION_ID = 'telegram:chat:22222222'
  CORRESPONDENT_ID = 'telegram:user:11111111'
  NOW = Time.utc(2026, 8, 10, 12, 0, 0)
  TURN_TEXT = 'make the header blue'
  LONG_TEXT = "repaint the whole page #{'x' * 1500}"
  VOLATILE_FIELDS = %w[thread_id checkpoint_id sequence audit_digest].freeze

  def test_each_control_reachable_from_both_surfaces_yields_the_same_projection_fields
    with_dual_surface do |surface|
      surface.admit(101, TURN_TEXT)

      ['/think high', '/verbose detailed', '/reset', '/compact', '/usage', '/context']
        .each_with_index do |text, index|
        surface.command(text, 200 + index)
      end

      cli_thread = 'th_exposure_cli'
      seed_cli_turn(surface, cli_thread, TURN_TEXT)
      cli_commands = {
        'think' => ['think', cli_thread, 'high'],
        'verbose' => ['verbose', cli_thread, 'detailed'],
        'reset' => ['reset', cli_thread],
        'compact' => ['compact', cli_thread],
        'usage' => ['usage', cli_thread],
        'context' => ['context', cli_thread]
      }
      cli_documents = cli_commands.transform_values { |argv| surface.run_cli(argv) }

      %w[think verbose reset compact usage context].each do |name|
        gateway_document = surface.captured.fetch(name).last
        cli_document = cli_documents.fetch(name)

        assert_equal gateway_document.keys.sort, cli_document.keys.sort,
                     "#{name} must project the same document schema on both surfaces"
        assert_equal meaning(gateway_document), meaning(cli_document),
                     "#{name} must mean the same thing on both surfaces"
      end

      assert_equal({ 'reasoning_depth' => 'high' }, cli_documents.fetch('think').fetch('preferences'))
      assert_equal 1, cli_documents.fetch('reset').fetch('truncated_fragments')
      assert_equal({ 'turn' => 1 }, cli_documents.fetch('usage').fetch('requests'))
    end
  end

  def test_a_bad_think_value_is_a_typed_bounded_reply_and_writes_nothing
    with_dual_surface do |surface|
      surface.admit(101, TURN_TEXT)
      surface.command('/think high', 102)
      thread = surface.current_thread
      tip_before = latest_tip_id(surface.session, thread)

      assert_equal 1, control_count(surface.session, thread)

      bad_values(surface, thread)

      assert_equal 1, control_count(surface.session, thread),
                   'a refused preference must not write any audit record'
      assert_equal tip_before, latest_tip_id(surface.session, thread),
                   'a refused preference must not advance the checkpoint chain'
    end
  end

  def test_compact_pins_the_transcript_and_the_pinned_digests_show_in_context_afterwards
    with_dual_surface do |surface|
      surface.admit(101, LONG_TEXT)
      surface.command('/think low', 102)
      surface.command('/compact', 103)
      surface.command('/context', 104)

      compact_line = surface.reply_for(103)
      context_line = surface.reply_for(104)
      assert_equal 'Transcript compacted; 1 fragments externalized behind pinned digests.', compact_line
      assert_includes context_line, 'earlier summary pinned'
      assert_includes context_line, 'fragments visible 0 of 1 (1 truncated by controls)'

      pinned = surface.captured.fetch('context').last
        .dig('layers', 'transcript', 'earlier_summary_pinned')
      assert_equal true, pinned

      cli_thread = 'th_compact_cli'
      seed_cli_turn(surface, cli_thread, LONG_TEXT)
      surface.run_cli(['think', cli_thread, 'low'])
      compacted = surface.run_cli(['compact', cli_thread])
      composition = surface.run_cli(['context', cli_thread])

      assert_equal 1, compacted.fetch('truncated_fragments')
      assert_equal true, composition.dig('layers', 'transcript', 'earlier_summary_pinned')
      assert_equal 0, composition.dig('layers', 'transcript', 'fragments_visible')
    end
  end

  def test_controls_after_new_address_the_successor_generation_automatically
    with_dual_surface do |surface|
      surface.admit(101, TURN_TEXT)

      assert_equal Comms::Gateway::CONTROLS_NO_SESSION_REPLY, surface.command('/usage', 102),
                   'a read-only control on an untouched thread refuses typed'

      old_thread = surface.current_thread
      surface.command('/think low', 103)
      surface.command('/new', 104)
      successor = surface.current_thread

      refute_equal old_thread, successor, '/new must rotate the addressed thread'

      surface.command('/think high', 105)
      surface.command('/context', 106)

      think_document = surface.captured.fetch('think').last
      assert_equal 'high', think_document.fetch('preferences').fetch('reasoning_depth')
      assert_equal successor, think_document.fetch('thread_id')
      assert_equal successor, surface.captured.fetch('context').last.fetch('thread_id')
      assert_equal [%w[think low]], control_records(surface.session, old_thread)
      assert_equal [%w[think high]], control_records(surface.session, successor)
    end
  end

  def test_read_only_controls_leave_the_state_digest_unchanged_on_both_surfaces
    with_dual_surface do |surface|
      surface.admit(101, TURN_TEXT)
      surface.command('/think medium', 102)
      thread = surface.current_thread
      before = tip_fingerprint(surface.session, thread)

      refute_empty surface.command('/usage', 103)
      refute_empty surface.command('/context', 104)

      assert_equal before, tip_fingerprint(surface.session, thread)

      cli_thread = 'th_readonly_cli'
      seed_cli_turn(surface, cli_thread, TURN_TEXT)
      surface.run_cli(['think', cli_thread, 'medium'])
      cli_before = cli_tip_fingerprint(surface, cli_thread)
      surface.run_cli(['usage', cli_thread])
      surface.run_cli(['context', cli_thread])

      assert_equal cli_before, cli_tip_fingerprint(surface, cli_thread)
    end
  end

  private

  def meaning(document)
    document.except(*VOLATILE_FIELDS)
  end

  def bad_values(surface, thread)
    {
      '/think maximum' => 'reasoning_depth must be one of low, medium, high (got "maximum")',
      '/think' => 'reasoning_depth must be one of low, medium, high (got nil)',
      '/verbose loud' => 'answer_verbosity must be one of quiet, normal, detailed (got "loud")'
    }.each do |text, expected|
      reply = surface.command(text, 300 + text.length)

      assert_equal expected, reply
      refute_includes reply, "\n", 'the failure must stay one bounded line'
    end
    assert_equal 1, control_count(surface.session, thread)
  end

  def control_count(session, thread)
    control_records(session, thread).length
  end

  def control_records(session, thread)
    tip = latest_tip(session, thread)
    return [] unless tip

    Array(tip.state[:context_controls]).map { |record| [record.fetch('control'), preference_word(record)] }
  end

  def preference_word(record)
    preferences = record['preferences']
    preferences.is_a?(Hash) ? preferences.values.first : nil
  end

  def latest_tip(session, thread)
    session.app.checkpointer.latest(thread_id: thread, namespace: [])
  end

  def latest_tip_id(session, thread)
    latest_tip(session, thread)&.id
  end

  def tip_fingerprint(session, thread)
    tip = latest_tip(session, thread)
    [tip.id, tip.sequence, Records.digest(tip.state.to_h)]
  end

  def cli_tip_fingerprint(surface, thread)
    session, _adapter = open_cli_session(surface, thread)
    tip = session.app.checkpointer.latest(thread_id: thread, namespace: [])
    [tip.id, tip.sequence, Records.digest(tip.state.to_h)]
  end

  # Opens the per-thread database the durable CLI writes, through the same
  # Session seam both the seeding and the reads go through.
  def open_cli_session(surface, thread)
    adapter = Tamoz::SQLite::Adapter.new(path: surface.cli_thread_path(thread))
    session = Tamoz::Agent::Session.new(
      model: ControlsModel.new,
      toolbox: Tamoz::Agent::Toolbox.new(root: surface.workspace),
      checkpointer: adapter,
      artifact_store: adapter.bind_artifact_store(tenant: "session:#{thread}"),
      artifact_tenant: "session:#{thread}"
    )
    [session, adapter]
  end

  # Seeds one admitted-but-unexecuted turn on a CLI thread so the transcript
  # carries a fragment: prior request payloads are the durable transcript.
  def seed_cli_turn(surface, thread, text)
    session, adapter = open_cli_session(surface, thread)
    begin
      session.app.durable_runner.submit(
        { 'task' => text }, thread:, request_id: SecureRandom.uuid, operation: :turn, delivery: :queue
      )
    ensure
      adapter.close
    end
  end

  # ===== harness =====

  Surface = Struct.new(:gateway, :transport, :store, :session, :recorded, :checkpoints,
                       :workspace, :session_dir, keyword_init: true) do
    def admit(id, text)
      transport.batch([ExposureUpdate.message(id, text)])
      raise "admission returned #{outcome}" unless gateway.serve_once(now: NOW + id, drain: false) == :served
    end

    def command(text, id)
      transport.batch([ExposureUpdate.message(id, text)])
      raise "command returned #{outcome}" unless gateway.serve_once(now: NOW + id, drain: false) == :served

      reply_for(id)
    end

    def reply_for(id)
      row = store.outbox_rows(surface_id: SURFACE_ID, statuses: %w[pending])
                 .find { |candidate| candidate.fetch('reply_to') == id + 10_000 }
      row && row.fetch('text')
    end

    def current_thread
      Comms::Admission.thread_id(
        SURFACE_ID, CONVERSATION_ID,
        generation: store.conversation_generation(surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID)
      )
    end

    def captured = recorded.captured

    def cli_thread_path(thread) = File.join(session_dir, "#{thread}.sqlite3")

    def run_cli(argv)
      out = StringIO.new
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(
        ['--session-dir', session_dir, '--root', workspace, '--json'] + argv,
        out:, err:, input: StringIO.new, env: {}, model_factory: ->(_options) { ControlsModel.new }
      )
      raise "cli #{argv.inspect} exited #{status}: #{err.string}" unless status.zero?

      JSON.parse(out.string.lines.last)
    end
  end

  # The session-access seam under test, built exactly as the CLI wiring builds
  # it: one profile-less Session over the shared runtime database.
  def controls_session(adapter, root)
    Tamoz::Agent::Session.new(
      model: ControlsModel.new,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: false),
      checkpointer: adapter,
      artifact_store: adapter.bind_artifact_store(tenant: 'channel:controls'),
      artifact_tenant: 'channel:controls'
    )
  end

  def with_dual_surface
    Dir.mktmpdir('tamoz-exposure') do |directory|
      workspace = File.join(directory, 'workspace')
      session_dir = File.join(directory, 'sessions')
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(session_dir, mode: 0o700)
      File.write(File.join(workspace, 'app.rb'), "value = 1\n")
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        checkpoints = graph_definition.compile(checkpointer: adapter).checkpointer
        store = adapter.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor.wire, now: NOW)
        store.bind_correspondent(binding_wire, now: NOW)
        recorded = RecordingControls.new(controls_session(adapter, workspace))
        transport = ScriptedTransport.new
        gateway = Comms::Gateway.new(
          adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'exposure:test',
          controls: ->(_thread) { recorded }
        )
        yield Surface.new(gateway:, transport:, store:, session: recorded, recorded:,
                          checkpoints:, workspace:, session_dir:)
      ensure
        adapter&.close
      end
    end
  end

  # The gateway's controls seam, instrumented: every projection document the
  # gateway surface produces is captured here for cross-surface comparison.
  class RecordingControls < SimpleDelegator
    attr_reader :captured

    def initialize(session)
      @captured = {}
      super
    end

    def reset_episode(thread:, request_id:)
      record('reset') { super }
    end

    def compact_transcript(thread:, request_id:)
      record('compact') { super }
    end

    def usage_report(thread:)
      record('usage') { super }
    end

    def context_report(thread:)
      record('context') { super }
    end

    def set_reasoning_depth(thread:, request_id:, depth:)
      record('think') { super }
    end

    def set_answer_verbosity(thread:, request_id:, verbosity:)
      record('verbose') { super }
    end

    private

    def record(name)
      projection = yield
      (@captured[name] ||= []) << projection.document
      projection
    end
  end

  # Context controls plan and verify nothing; only /compact's summarization
  # stage reaches the model, and it must return the pinned-summary shape.
  class ControlsModel
    def generate(stage:, **)
      return JSON.generate('summary' => 'pinned summary text') if stage == :context_compact

      '{}'
    end
  end

  module ExposureUpdate
    module_function

    def message(id, text)
      { 'update_id' => id,
        'message' => { 'message_id' => id + 10_000, 'date' => 1_752_700_800,
                       'chat' => { 'id' => 22_222_222, 'type' => 'private' },
                       'from' => { 'id' => 111_111_11 }, 'text' => text } }
    end
  end

  class ScriptedTransport
    def batch(updates) = (@updates = updates)

    def poll(next_offset:, limit:, timeout_s:)
      ids = @updates.map { |update| update.fetch('update_id') }
      { updates: @updates.map { |update| normalize(update) }, next_offset: ids.max && (ids.max + 1) }
    end

    def deliver(_delivery)
      { 'message_id' => 1, 'date' => 1 }
    end

    def normalize(update)
      Comms::InboundEnvelope.new(
        surface_id: SURFACE_ID, surface_revision: 1,
        update_id: update.fetch('update_id'),
        raw_payload_hash: Digest::SHA256.hexdigest(JSON.generate(update)),
        parser_version: 1,
        kind: update.dig('message', 'text').start_with?('/') ? 'command' : 'text',
        correspondent_id: CORRESPONDENT_ID,
        conversation_id: CONVERSATION_ID,
        message_id: update.dig('message', 'message_id'),
        text: update.dig('message', 'text'),
        observed_time: Time.at(update.dig('message', 'date')).utc
      ).wire
    end
  end

  def descriptor
    @descriptor ||= Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: BOT_ID, bot_username: 'ops_bot' },
      admission: { direct: 'allowlist', correspondents: [CORRESPONDENT_ID] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 200, per_chat_messages_per_s: 30.0,
                global_messages_per_s: 100.0 }
    )
  end

  def binding_wire
    Comms::Binding.new(
      surface_id: SURFACE_ID, surface_revision: 1,
      correspondent_id: CORRESPONDENT_ID, conversation_id: CONVERSATION_ID,
      bound_at: NOW, bound_by: 'operator:test'
    ).wire
  end

  def graph_definition
    Tamoz.graph(name: 'exposure', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 'exposure.finish', version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
