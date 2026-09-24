# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'

# What reconnecting actually guarantees. A client that walks away mid-turn and
# comes back gets: the identity round-trip (the short reference resolves to the
# same request and thread) and resumption of STATE from durable rows alone with
# nothing re-run and no second terminal delivery.
#
# What it does NOT get — recorded here as a named limitation rather than
# invented: there is no protocol that resumes EVENT STREAMING from a last-seen
# sequence, so a reconnecting client reads current state; it never replays history.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
class ReconnectionResumeProtocolTest < Minitest::Test
  include AutonomyCase

  Comms = Tamoz::Comms

  SURFACE_ID = 'telegram-ops'
  BOT_ID = 7_463_512_990
  CONVERSATION = 'telegram:chat:33333333'
  THREAD = 'tg.ops.resume'
  NOW = Time.utc(2026, 8, 10, 12, 0, 0)

  def test_a_reconnecting_client_gets_identity_state_and_one_terminal_without_rerunning
    with_channel_runtime do |rt|
      admit_request!(rt)
      request_id = rt.with_engine do |_adapter, checkpoints|
        checkpoints.request_history(thread_id: THREAD).first.request_id
      end

      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
      runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { ScriptedModel.new(**read_only_responses) },
        lease_ttl: 5.0
      )
      begin
        worker = Tamoz::Agent::Worker.new(
          runtime:,
          session_builder: ->(thread) { runtime.session_for(thread) },
          emitter: ->(_event) {}, once: true
        )
        assert worker.poll_once

        reference = Comms::Lifecycle::RequestRef.for(request_id)
        view = runtime.session_for(THREAD).view(thread: THREAD)
        assert_equal :completed, view.status
      ensure
        runtime&.close
      end

      # Every writer is gone. The reconnect view answers from durable rows.
      status, out, err = rt.cli(['comms', 'request', reference])
      assert_equal 0, status, err
      assert_match(/request #{reference} on #{SURFACE_ID}\/#{CONVERSATION} \(thread #{THREAD}\)/, out)
      assert_match(/task=completed delivery=\w+ open_requests=0 state=idle/, out)

      status, out, err = rt.cli(['comms', 'request', reference, '--json'])
      assert_equal 0, status, err
      row = JSON.parse(out.lines.last).fetch('requests').first
      assert_equal reference, row.fetch('request_ref'), 'identity round-trips through the short ref'
      assert_equal THREAD, row.fetch('thread_id')
      assert_equal request_id, row.fetch('request_id')
      assert row.key?('task_state')
      assert row.key?('delivery_state')

      # Nothing re-ran and no second terminal appeared during reconnection.
      rt.with_engine do |adapter, checkpoints|
        store = adapter.bind_comms_store(checkpoints)
        assert_equal 1, checkpoints.request_history(thread_id: THREAD).length,
                     'reconnection must not enqueue or run the turn again'
        assert_equal 1, answer_rows(store),
                     'reconnection must not duplicate the terminal delivery'
      end
    end
  end

  private

  def read_only_responses
    {
      plan: [plan_step('read_file', { 'path' => 'note.txt' })],
      review: [accepted_review],
      verify: [{ 'answer' => 'hello', 'satisfied' => true, 'evidence' => ['note.txt'] }]
    }
  end

  def answer_rows(store)
    store.outbox_rows(surface_id: SURFACE_ID,
                      statuses: %w[pending claimed succeeded failed unknown])
         .count { |row| row.fetch('conversation_id') == CONVERSATION && row.fetch('kind') == 'answer' }
  end

  def admit_request!(rt)
    rt.with_store do |store|
      store.deploy_surface(descriptor.wire, now: NOW)
      store.bind_conversation(
        Comms::Conversation.new(
          surface_id: SURFACE_ID, surface_revision: 1,
          conversation_id: CONVERSATION, thread_id: THREAD,
          profile_id: 'ops', bound_at: NOW
        ).wire, now: NOW
      )
      assert_equal :enqueued, store.admit_and_enqueue(
        envelope(update_id: 401), surface_id: SURFACE_ID, bot_id: BOT_ID,
        thread: THREAD, profile_id: 'ops', reservation: 1, now: NOW
      )
    end
  end

  def descriptor
    Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: BOT_ID, bot_username: 'ops_bot' },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  def envelope(update_id:)
    Comms::InboundEnvelope.new(
      surface_id: SURFACE_ID, surface_revision: 1, update_id:,
      raw_payload_hash: format('%064x', update_id), parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111', conversation_id: CONVERSATION,
      message_id: update_id + 20_000, text: 'hello', observed_time: NOW
    ).wire
  end

  def with_channel_runtime
    Dir.mktmpdir('tamoz-resume') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      workspace = File.join(directory, 'workspace')
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)
      File.write(File.join(workspace, 'note.txt'), "hello\n")
      File.write(File.join(runtime_dir, 'config.yaml'), Psych.dump(
                                                          'runtime' => { 'schema_version' => 2 },
                                                          'workspace' => { 'root' => workspace },
                                                          'sources' => {},
                                                          'channels' => {
                                                            SURFACE_ID => {
                                                              'kind' => 'telegram', 'revision' => 1,
                                                              'enabled' => false, 'profile' => 'trusted',
                                                              'credential_ref' => {
                                                                'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN'
                                                              },
                                                              'expected_bot_id' => BOT_ID,
                                                              'admission' => { 'direct' => 'pairing',
                                                                               'correspondents' => [] }
                                                            }
                                                          }
                                                        ))
      File.chmod(0o600, File.join(runtime_dir, 'config.yaml'))
      write_read_only_profile(runtime_dir, workspace)
      yield ChannelRuntime.new(dir: runtime_dir)
    end
  end

  # A read-only authority: the reconnect scenario needs a turn that completes
  # verified without a configured check, which an action-capable profile would
  # refuse (`no_check`).
  def write_read_only_profile(runtime_dir, workspace)
    digest = Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes: false, checks: {},
      allowed_tools: READ_ONLY_TOOLS
    ).catalog_digest
    directory = File.join(runtime_dir, 'profiles')
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, directory)
    path = File.join(directory, 'trusted.yaml')
    File.write(path, Psych.dump(
      'profile' => {
        'schema_version' => 1, 'profile_id' => 'trusted', 'profile_version' => '1.0',
        'canonical_root' => workspace
      },
      'roots' => { 'workspace' => workspace },
      'tools' => { 'allowed' => READ_ONLY_TOOLS },
      'policy' => {
        'allow_changes' => false, 'default_check_safety' => 'read_only',
        'graph_version' => '1', 'behavior_version' => '1.0',
        'tool_catalog_digest' => digest, 'unattended_catalog_digest' => digest
      }
    ))
    File.chmod(0o600, path)
  end

  # One operator-owned runtime directory: durable rows in, CLI answers out.
  class ChannelRuntime
    include AutonomyCase

    attr_reader :dir

    def initialize(dir:)
      @dir = dir
    end

    def cli(argv)
      out = StringIO.new
      err = StringIO.new
      exit_code = Tamoz::Agent::CLI.run(
        ['--runtime-dir', dir] + argv,
        out:, err:, input: StringIO.new,
        env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' }
      )
      [exit_code, out.string, err.string]
    end

    def with_store
      with_engine do |adapter, checkpoints|
        yield adapter.bind_comms_store(checkpoints)
      end
    end

    def with_engine
      require 'tamoz/sqlite'
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, 'runtime.sqlite3'))
      definition = Tamoz.graph(name: 't', version: '1') do
        state :ready, default: true
        node(:finish, implementation_name: 't.finish', version: '1') { |_s, _c| { ready: true } }
        edge Tamoz::START, :finish
        edge :finish, Tamoz::END
      end
      yield adapter, definition.compile(checkpointer: adapter).checkpointer
    ensure
      adapter&.close
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
