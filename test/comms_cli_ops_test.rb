# frozen_string_literal: true

require_relative 'test_helper'

# Slice I (COMMS_TELEGRAM_PLAN §3) — the pairing and recovery operator
# surface (COMMS_DESIGN §7/§14): `tamoz comms pair list|approve|revoke`
# (approval consumes the challenge and writes the binding in one step) and
# `tamoz comms delivery resolve` (a genuinely ambiguous send is resolved by
# the operator, never retried blindly).
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Metrics/BlockLength, Metrics/CyclomaticComplexity
# rubocop:disable Naming/MethodParameterName, Lint/UnusedMethodArgument, Metrics/ParameterLists
class CommsCliOpsTest < Minitest::Test
  BOT_ID = 7_463_512_990
  CODE = 'a1b2c3d4e5f60718'

  def channel_entry(admission: 'pairing')
    {
      'kind' => 'telegram', 'revision' => 1, 'enabled' => true,
      'profile' => 'ops',
      'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
      'expected_bot_id' => BOT_ID,
      'admission' => { 'direct' => admission, 'correspondents' => [] }
    }
  end

  def with_rt(channels: { 'telegram-ops' => channel_entry })
    Dir.mktmpdir('tamoz-comms-ops') do |directory|
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
      yield Harness.new(runtime_dir, workspace)
    end
  end

  # `pair approve` consumes ONE challenge and writes the binding in the same
  # transaction, then the approved correspondent is admitted in pairing mode.
  def test_pair_approve_writes_a_binding_and_the_paired_sender_is_admitted
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      challenge = Tamoz::Comms::PairingChallenge.build(
        surface_id: 'telegram-ops', correspondent_id: 'telegram:user:11111111',
        conversation_id: 'telegram:chat:22222222', ttl_s: 3600,
        now: Time.now.utc
      )
      with_store(rt) do |store|
        store.insert_pairing_challenge(
          digest: challenge.digest, surface_id: 'telegram-ops',
          correspondent_id: 'telegram:user:11111111',
          conversation_id: 'telegram:chat:22222222',
          expires_at: challenge.expires_at, now: Time.now.utc
        )
      end

      status, out, err = rt.cli(%w[comms pair approve], env: {}, code: challenge.challenge)

      assert_equal 0, status, err
      assert_match(/paired telegram:user:11111111/, out)
      with_store(rt) do |store|
        assert_empty store.pairing_challenges(status: 'pending')
        binding = store.binding(correspondent_id: 'telegram:user:11111111', surface_id: 'telegram-ops')

        assert_equal 'active', binding.fetch('status')
        assert_equal 'telegram:chat:22222222', binding.fetch('conversation_id')
      end

      # The paired sender's next message is a real request (pairing mode now
      # admits on the approved binding).
      rt.client.updates = [message_update(70, text: 'hello after pairing')]

      assert_equal 0, rt.cli(%w[comms serve --once]).first
      with_store(rt) do |store|
        assert_equal 71, store.poll_state(bot_id: BOT_ID).fetch('next_offset')
      end
    end
  end

  def test_pair_approve_refuses_a_foreign_code_and_an_expired_one
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      challenge = Tamoz::Comms::PairingChallenge.build(
        surface_id: 'telegram-ops', correspondent_id: 'telegram:user:11111111',
        conversation_id: 'telegram:chat:22222222', ttl_s: 3600,
        now: Time.now.utc
      )
      with_store(rt) do |store|
        store.insert_pairing_challenge(
          digest: challenge.digest, surface_id: 'telegram-ops',
          correspondent_id: 'telegram:user:11111111',
          conversation_id: 'telegram:chat:22222222',
          expires_at: Time.now.utc + 300, now: Time.now.utc
        )
      end

      status, _out, err = rt.cli(%w[comms pair approve], code: 'wrong-code')

      assert_equal 1, status
      assert_match(/no pending pairing code matches/, err)
      with_store(rt) do |store|
        assert_equal 1, store.pairing_challenges(status: 'pending').length,
                     'a refused code must not consume the challenge'
      end
    end

    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      challenge = Tamoz::Comms::PairingChallenge.build(
        surface_id: 'telegram-ops', correspondent_id: 'telegram:user:11111111',
        conversation_id: 'telegram:chat:22222222', ttl_s: 1,
        now: Time.now.utc - 120
      )
      with_store(rt) do |store|
        store.insert_pairing_challenge(
          digest: challenge.digest, surface_id: 'telegram-ops',
          correspondent_id: 'telegram:user:11111111',
          conversation_id: 'telegram:chat:22222222',
          expires_at: Time.now.utc - 60, now: Time.now.utc - 120
        )
      end

      status, _out, err = rt.cli(%w[comms pair approve], code: challenge.challenge)

      assert_equal 1, status
      assert_match(/no pending pairing code matches/, err,
                   'an expired code is not approvable: it never scans as pending')
      with_store(rt) do |store|
        assert_empty store.pairing_challenges(status: 'pending'),
                     'the expired challenge is excluded from pending scans'
        assert_equal 1, store.pairing_challenges.length,
                     'the expired row stays in the table for the audit trail'
      end
    end
  end

  def test_pair_list_shows_pending_codes_and_active_bindings
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      challenge = Tamoz::Comms::PairingChallenge.build(
        surface_id: 'telegram-ops', correspondent_id: 'telegram:user:11111111',
        conversation_id: 'telegram:chat:22222222', ttl_s: 3600,
        now: Time.now.utc
      )
      with_store(rt) do |store|
        store.insert_pairing_challenge(
          digest: challenge.digest, surface_id: 'telegram-ops',
          correspondent_id: 'telegram:user:11111111',
          conversation_id: 'telegram:chat:22222222',
          expires_at: challenge.expires_at, now: Time.now.utc
        )
      end

      status, out, err = rt.cli(%w[comms pair list])

      assert_equal 0, status, err
      assert_match(/pending #{challenge.digest[0, 12]} telegram:user:11111111/, out)

      assert_equal 0, rt.cli(%w[comms pair approve], code: challenge.challenge).first
      status, out, err = rt.cli(%w[comms pair list])

      assert_equal 0, status, err
      assert_match(/active telegram:user:11111111/, out)
      refute_match(/pending/, out)
    end
  end

  def test_pair_revoke_lists_admitted_work_and_the_cancel_commands
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      with_store(rt) do |store|
        store.bind_correspondent(binding_wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
        store.bind_conversation(conversation_wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
      end

      status, out, err = rt.cli(%w[comms pair revoke telegram:user:11111111])

      assert_equal 0, status, err
      assert_match(/revoked telegram:user:11111111 on telegram-ops/, out)
      expected_thread = Tamoz::Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222')

      assert_match(/admitted work on #{expected_thread}: tamoz cancel #{expected_thread}/, out)
      with_store(rt) do |store|
        binding = store.binding(correspondent_id: 'telegram:user:11111111', surface_id: 'telegram-ops')

        assert_equal 'revoked', binding.fetch('status')
      end
    end
  end

  def test_delivery_resolve_marks_an_unknown_send_and_prints_the_effect
    with_rt do |rt|
      assert_equal 0, rt.cli(%w[comms serve --once]).first
      with_store(rt) do |store|
        store.append_delivery(delivery_wire, surface_id: 'telegram-ops', capacity: 500,
                                             now: Time.now.utc)
        delivery_id = delivery_wire.fetch('delivery_id')
        store.claim_delivery(delivery_id:, owner: 'gateway:test', fence: 1,
                             claim_expires_at: Time.now.utc + 60, now: Time.now.utc)
        store.mark_delivery(delivery_id:, owner: 'gateway:test', fence: 1,
                            status: 'unknown', now: Time.now.utc)
      end

      status, out, err = rt.cli(%w[comms delivery resolve], delivery_id: delivery_wire.fetch('delivery_id'),
                                                            status: 'succeeded')

      assert_equal 0, status, err
      assert_match(/resolved .* as succeeded \(effect .*\)/, out)
      with_store(rt) do |store|
        counts = store.outbox_counts(surface_id: 'telegram-ops')

        assert_equal 1, counts.fetch('succeeded')
        refute counts.key?('unknown')
      end
    end
  end

  def test_delivery_resolve_refuses_a_foreign_id_and_a_bad_status
    with_rt do |rt|
      status, _out, err = rt.cli(%w[comms delivery resolve nope succeeded])

      assert_equal 1, status
      assert_match(/no unknown delivery/, err)
    end
    with_rt do |rt|
      status, _out, err = rt.cli(%w[comms delivery resolve id retry])

      assert_equal 64, status
      assert_match(/STATUS must be succeeded or failed/, err)
    end
  end

  private

  def with_store(rt)
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(rt.dir, 'runtime.sqlite3'))
    definition = Tamoz.graph(name: 't', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 't.finish', version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    checkpoints = definition.compile(checkpointer: adapter).checkpointer
    yield adapter.bind_comms_store(checkpoints)
  ensure
    adapter&.close
  end

  def message_update(id, text:, user_id: 111_111_11)
    { 'update_id' => id,
      'message' => { 'message_id' => id + 10_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 222_222_22, 'type' => 'private' },
                     'from' => { 'id' => user_id }, 'text' => text } }
  end

  def binding_wire
    Tamoz::Comms::Binding.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      correspondent_id: 'telegram:user:11111111',
      conversation_id: 'telegram:chat:22222222',
      bound_at: Time.utc(2026, 8, 10, 12, 0, 0), bound_by: 'operator:test'
    ).wire
  end

  def conversation_wire
    Tamoz::Comms::Conversation.new(
      surface_id: 'telegram-ops', surface_revision: 1,
      conversation_id: 'telegram:chat:22222222',
      thread_id: Tamoz::Comms::Admission.thread_id('telegram-ops', 'telegram:chat:22222222'),
      profile_id: 'ops', bound_at: Time.utc(2026, 8, 10, 12, 0, 0)
    ).wire
  end

  def delivery_wire
    Tamoz::Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'answer', text: 'hello',
      part_index: 0, part_count: 1, journaled: true,
      render_version: Tamoz::Comms::Rendering::RENDER_VERSION,
      content_digest: Tamoz::Comms::Rendering.content_digest('hello')
    ).wire
  end

  class Harness
    attr_reader :dir, :workspace, :client

    def initialize(dir, workspace)
      @dir = dir
      @workspace = workspace
      @client = FakeTelegramClient.new
    end

    def cli(argv, env: {}, factory: nil, code: nil, delivery_id: nil, status: nil)
      args = ['--runtime-dir', dir] + argv
      args += [code] if code
      args += [delivery_id, status] if delivery_id
      out = StringIO.new
      err = StringIO.new
      exit_code = Tamoz::Agent::CLI.run(
        args,
        out:, err:, input: StringIO.new,
        env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' }.merge(env),
        comms_client_factory: factory || ->(_token) { client }
      )
      [exit_code, out.string, err.string]
    end
  end

  class FakeTelegramClient
    attr_accessor :updates

    def initialize
      @updates = []
      @offset = 0
      @sent = []
    end

    def call(method, params, idempotent: false)
      case method
      when 'getMe' then { 'id' => BOT_ID, 'username' => 'ops_bot', 'is_bot' => true, 'first_name' => 'Ops' }
      when 'getUpdates'
        taken, remaining = @updates.partition { |update| update.fetch('update_id') > @offset }
        @updates = remaining
        @offset = taken.map { |update| update.fetch('update_id') }.max || @offset
        taken
      when 'sendMessage', 'editMessageText'
        @sent << params
        { 'message_id' => @sent.length, 'date' => 1_752_700_800 }
      when 'answerCallbackQuery' then true
      when 'getWebhookInfo' then { 'url' => '' }
      else
        raise ArgumentError, "unexpected method #{method}"
      end
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:enable Metrics/BlockLength, Metrics/CyclomaticComplexity
# rubocop:enable Naming/MethodParameterName, Lint/UnusedMethodArgument, Metrics/ParameterLists
