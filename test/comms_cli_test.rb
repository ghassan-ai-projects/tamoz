# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/comms_cli_fixture'

# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Lint/UnusedMethodArgument, Lint/UnderscorePrefixedVariableName
class CommsCliTest < Minitest::Test
  include CommsCliFixture

  BOT_ID = 7_463_512_990

  def channel_entry(admission: 'allowlist', stream_id: "telegram:bot:#{BOT_ID}")
    {
      'kind' => 'telegram', 'revision' => 1, 'enabled' => true,
      'profile' => 'ops',
      'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
      'stream_id' => stream_id,
      'admission' => { 'direct' => admission, 'correspondents' => ['telegram:user:11111111'] }
    }
  end

  def with_rt(channels: { 'telegram-ops' => channel_entry }, client: FakeTelegramClient.new)
    Dir.mktmpdir('tamoz-comms-cli') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      workspace = File.join(directory, 'workspace')
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)
      File.write(File.join(runtime_dir, 'config.yaml'), Psych.dump(
                                                          'runtime' => { 'schema_version' => 2 },
                                                          'workspace' => { 'root' => workspace },
                                                          'sources' => {},
                                                          'channels' => channels
                                                        ))
      File.chmod(0o600, File.join(runtime_dir, 'config.yaml'))
      CommsRuntimeProfile.write(runtime_dir, workspace)
      yield Harness.new(runtime_dir, workspace, client)
    end
  end

  def test_serve_once_deploys_the_surface_and_exits_cleanly
    with_rt do |rt|
      status, out, err = rt.cli(%w[comms serve --once --json])

      assert_equal 0, status, err
      assert_equal ['served'], JSON.parse(out)
      _status, list, err = rt.cli(%w[comms list --json])

      assert_equal 0, _status, err
      surfaces = JSON.parse(list)

      assert_equal(['telegram-ops'], surfaces.map { |row| row.fetch('surface_id') })
      assert_equal 1, surfaces.first.fetch('revision')
    end
  end

  def test_an_inbound_message_becomes_a_queued_request_and_the_offset_persists
    with_rt do |rt|
      rt.client.updates = [message_update(55, text: 'hello from telegram')]
      status, _out, err = rt.cli(%w[comms serve --once])

      assert_equal 0, status, err
      with_store(rt) do |store|
        poll = store.poll_state(stream_id: "telegram:bot:#{BOT_ID}")

        assert_equal 56, poll.fetch('next_offset'), 'the durable offset must confirm the prefix'
        pending = store.pairing_challenges(status: 'pending')

        assert_empty pending
      end
    end
  end

  def test_an_unbound_sender_is_durably_rejected_and_never_reaches_a_turn
    with_rt do |rt|
      rt.client.updates = [message_update(60, text: 'hello', user_id: 999_999_99)]
      status, _out, err = rt.cli(%w[comms serve --once])

      assert_equal 0, status, err
      audit = with_store(rt, &:admission_audit_counts)

      assert_equal 0, audit.fetch('unauthorized_inbound_admissions'),
                   'an unbound sender must never become a request'
    end
  end

  def test_comms_list_shows_bindings_routes_and_outbox_depth
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      with_store(rt) do |store|
        store.bind_correspondent(binding_wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
        store.bind_conversation(conversation_wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
        store.append_delivery(delivery_wire, surface_id: 'telegram-ops', capacity: 500,
                                             now: Time.utc(2026, 8, 10, 12, 0, 0))
      end

      _status, out, err = rt.cli(%w[comms list --json])

      assert_equal 0, _status, err
      surface = JSON.parse(out).first

      assert_equal 1, surface.fetch('bindings').length
      assert_equal 'telegram:user:11111111', surface.fetch('bindings').first.fetch('correspondent_id')
      expected_thread = Tamoz::Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_equal expected_thread, surface.fetch('conversations').first.fetch('thread_id')
      assert_equal 1, surface.fetch('outbox').fetch('pending')
    end
  end

  def test_a_second_serve_cannot_take_the_lease_so_it_neither_listens_nor_delivers
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      with_store(rt) do |store|
        store.append_delivery(delivery_wire, surface_id: 'telegram-ops', capacity: 500, now: Time.now.utc)
        store.acquire_poller_lease(surface_id: 'telegram-ops', stream_id: "telegram:bot:#{BOT_ID}", lease: Tamoz::Comms::Lease.new(owner: 'gateway:999', fence: 1),
                                   ttl_s: 60, now: Time.now.utc)
      end

      status, _out, err = Timeout.timeout(10) { rt.cli(%w[comms serve]) }

      assert_equal 1, status
      assert_includes err, 'another run holds telegram-ops'
      assert_equal 1, with_store(rt) { |store| store.outbox_counts(surface_id: 'telegram-ops') }.fetch('pending', 0),
                   'a run without the lease must not claim a delivery'
    end
  end

  def test_status_has_a_channels_section_with_safety_counters
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first

      status, out, err = rt.cli(%w[status --json])

      assert_equal 0, status, err
      channels = JSON.parse(out).fetch('channels')

      assert_equal(['telegram-ops'], channels.fetch('surfaces').map { |row| row.fetch('surface_id') })
      counters = channels.fetch('safety_counters')

      assert_equal 0, counters.fetch('unauthorized_inbound_admissions')
      assert_equal 0, counters.fetch('chat_grants')
      assert_equal 0, counters.fetch('credential_in_durable_record')
    end
  end

  # ------------------------------------------------------------------ doctor

  def test_doctor_passes_for_a_healthy_surface
    with_rt do |rt|
      status, out, err = rt.cli(%w[comms doctor], env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' })

      assert_equal 0, status, err
      assert_match(/ok    runtime permissions/, out)
      assert_match(/ok    bot id/, out)
      assert_match(/ok    webhook/, out)
      assert_match(/ok    poller/, out)
    end
  end

  def test_doctor_names_wrong_bot_id_webhook_and_poller_conflicts
    with_rt(client: FakeTelegramClient.new(bot_id: 111_111_111)) do |rt|
      rt.client.webhook_url = 'https://example.com/hook'
      rt.client.updates = []

      assert_equal 1, rt.cli(%w[comms serve --once], env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' }).first,
                   'serving must stop when getMe identifies the wrong configured bot'
      rt.client.updates = []
      # Re-acquire a live poller lease the doctor must see as foreign.
      with_store(rt) do |store|
        store.acquire_poller_lease(surface_id: 'telegram-ops', stream_id: "telegram:bot:#{BOT_ID}",
                                   lease: Tamoz::Comms::Lease.new(owner: 'gateway:999', fence: 1), ttl_s: 60,
                                   now: Time.now.utc)
      end

      status, out, err = rt.cli(%w[comms doctor], env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' })

      assert_equal 1, status, err
      assert_match(/FAIL  bot id: token authenticates telegram:bot:111111111/, out)
      assert_match(%r{FAIL  webhook: a webhook is set at https://example.com/hook}, out)
      assert_match(/FAIL  poller: another gateway \(gateway:999\) holds the poller lease/, out)
    end
  end

  def test_doctor_names_a_missing_token_and_a_missing_adapter
    with_rt do |rt|
      status, out, err = rt.cli(%w[comms doctor], env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => nil })

      assert_equal 1, status, err
      assert_match(/FAIL  token TAMOZ_TELEGRAM_BOT_TOKEN: credential .* is not set/, out)
    end

    with_rt do |rt|
      missing = Tamoz::Agent::ChannelKind.new(name: 'telegram', library: 'tamoz/no_such_adapter',
                                              namespace: 'Tamoz::NoSuchAdapter')
      status, out, err = rt.cli(%w[comms doctor], kinds: Tamoz::Agent::CHANNEL_KINDS.merge('telegram' => missing))

      assert_equal 1, status, err
      assert_match(/FAIL  adapter: the telegram channel \(tamoz-no_such_adapter\) is not installed/, out)
    end
  end

  def test_doctor_names_a_permissions_failure
    with_rt do |rt|
      File.chmod(0o755, rt.dir)

      status, out, err = rt.cli(%w[comms doctor])

      assert_equal 1, status, err
      assert_match(/FAIL  runtime permissions: .* accessible to group or others/, out)
    end
  end

  # R1 (declared cap honesty): the PRODUCTION Telegram channel builds the real
  # client carrying the surface's declared max_response_bytes; an undeclared
  # cap falls through to the client's own default.
  def test_the_production_client_carries_the_declared_response_cap
    built = []
    channel = Tamoz::Telegram::Channel.new
    channel.define_singleton_method(:client) { |*args| super(*args).tap { built << _1 } }
    env = { 'TAMOZ_TELEGRAM_BOT_TOKEN' => 'token' }

    channel.connect(telegram_descriptor(4096), env:)
    declared = built.last

    assert_kind_of Tamoz::Telegram::Client, declared
    assert_equal 4096, declared.max_response_bytes

    channel.connect(telegram_descriptor(nil), env:)
    undeclared = built.last

    assert_equal Tamoz::Telegram::Client::DEFAULT_MAX_RESPONSE_BYTES, undeclared.max_response_bytes
  end

  private

  def telegram_descriptor(max_response_bytes)
    Tamoz::Comms::SurfaceDescriptor.build(
      kind: 'telegram',
      surface_id: 'telegram-ops', revision: 1,
      transport: { credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: },
      identity: { stream_id: "telegram:bot:#{BOT_ID}" }, settings: { bot_username: 'ops_bot' },
      admission: { direct: 'disabled' }, threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'none', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  def message_update(id, text:, user_id: 111_111_11)
    { 'update_id' => id,
      'message' => { 'message_id' => id + 10_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                     'from' => { 'id' => user_id }, 'text' => text } }
  end

  class Harness
    attr_reader :dir, :workspace, :client

    def initialize(dir, workspace, client)
      @dir = dir
      @workspace = workspace
      @client = client
    end

    def cli(argv, env: {}, factory: nil, kinds: nil)
      out = StringIO.new
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(
        ['--runtime-dir', dir] + argv,
        out:, err:, input: StringIO.new,
        env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' }.merge(env),
        channel_kinds: kinds || ChannelKindsFixture.telegram(factory || ->(_token) { client })
      )
      [status, out.string, err.string]
    end
  end

  class FakeTelegramClient
    attr_reader :origin
    attr_accessor :updates, :bot_id, :webhook_url

    def initialize(bot_id: BOT_ID, origin: 'https://api.telegram.org')
      @bot_id = bot_id
      @origin = origin
      @updates = []
      @webhook_url = ''
      @offset = 0
      @sent = []
    end

    def call(method, params, idempotent: false)
      case method
      when 'getMe' then { 'id' => @bot_id, 'username' => 'ops_bot', 'is_bot' => true, 'first_name' => 'Ops' }
      when 'getUpdates'
        taken, remaining = @updates.partition { |update| update.fetch('update_id') > @offset }
        @updates = remaining
        @offset = taken.map { |update| update.fetch('update_id') }.max || @offset
        taken
      when 'sendMessage', 'editMessageText'
        @sent << params
        { 'message_id' => @sent.length, 'date' => 1_752_700_800 }
      when 'answerCallbackQuery' then true
      when 'getWebhookInfo' then { 'url' => @webhook_url }
      else
        raise ArgumentError, "unexpected method #{method}"
      end
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize
# rubocop:enable Metrics/CyclomaticComplexity
# rubocop:enable Lint/UnusedMethodArgument, Lint/UnderscorePrefixedVariableName
