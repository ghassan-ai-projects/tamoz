# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_transport_fixture'

class TamozTelegramTransportAttachmentTest < Minitest::Test
  include TelegramTransportFixture

  Comms = Tamoz::Comms

  def test_fetch_attachment_reads_the_file_getfile_names
    with_transport do |transport, server|
      server.script('getFile', body: { 'ok' => true, 'result' => { 'file_id' => 'D1', 'file_size' => 5,
                                                                   'file_path' => 'documents/file_7.txt' } }, times: 1)
      server.script('file_7.txt', raw: 'hello', times: 1)

      assert_equal 'hello', transport.fetch_attachment('D1', max_bytes: 100)
      assert_equal '/file/bottest-token/documents/file_7.txt', server.requests.last.fetch(:path)
    end
  end

  def test_an_announced_oversize_file_is_refused_before_any_download
    with_transport do |transport, server|
      server.script('getFile', body: { 'ok' => true, 'result' => { 'file_id' => 'D1', 'file_size' => 101,
                                                                   'file_path' => 'documents/big.pdf' } }, times: 1)

      assert_raises(Comms::ResponseTooLargeError) { transport.fetch_attachment('D1', max_bytes: 100) }
      assert_equal(%w[getFile], server.requests.map { |request| request.fetch(:method) })
    end
  end

  def test_a_download_that_outgrows_its_limit_is_abandoned
    with_transport do |transport, server|
      server.script('getFile', body: { 'ok' => true, 'result' => { 'file_id' => 'D1',
                                                                   'file_path' => 'documents/file_8.bin' } }, times: 1)
      server.script('file_8.bin', raw: 'x' * 101, times: 1)

      assert_raises(Comms::ResponseTooLargeError) { transport.fetch_attachment('D1', max_bytes: 100) }
    end
  end

  def test_a_file_path_cannot_leave_the_file_endpoint
    with_transport do |transport, server|
      ['../../botother/getMe', '/etc/passwd', "documents/a\nb", 'a/../../x'].each do |path|
        server.script('getFile', body: { 'ok' => true, 'result' => { 'file_id' => 'D1', 'file_path' => path } },
                                 times: 1)

        assert_raises(Comms::ValidationError, path) { transport.fetch_attachment('D1', max_bytes: 100) }
      end
      assert_equal(%w[getFile] * 4, server.requests.map { |request| request.fetch(:method) })
    end
  end

  def test_telegrams_too_big_refusal_is_too_large_not_transient
    with_transport do |transport, server|
      server.script('getFile', status: 400, body: { 'ok' => false, 'error_code' => 400,
                                                    'description' => 'Bad Request: file is too big' }, times: 1)

      assert_raises(Comms::ResponseTooLargeError) { transport.fetch_attachment('D1', max_bytes: 100) }
    end
  end

  def test_a_download_past_its_deadline_is_abandoned
    server = TelegramFixtureServer.new
    client = Tamoz::Telegram::Client.new('test-token', origin: server.url, read_timeout: 1.0, download_deadline: -1.0)
    transport = Tamoz::Telegram::Transport.new(
      client:, normalizer: Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)
    )
    server.script('getFile', body: { 'ok' => true, 'result' => { 'file_id' => 'D1',
                                                                 'file_path' => 'documents/slow.bin' } }, times: 1)
    server.script('slow.bin', raw: 'x' * 10, times: 1)

    assert_raises(Comms::TransientTransportError) { transport.fetch_attachment('D1', max_bytes: 100) }
  ensure
    server&.stop
  end

  def test_getfile_waits_no_longer_than_a_download_read
    calls = []
    client = Object.new
    client.define_singleton_method(:call) do |method, _params, **options|
      calls << [method, options]
      { 'file_path' => 'documents/a.txt' }
    end
    client.define_singleton_method(:download) { |*, **| 'ok' }
    normalizer = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)

    Tamoz::Telegram::Transport.new(client:, normalizer:).fetch_attachment('D1', max_bytes: 10)

    assert_equal [['getFile', { idempotent: true, read_timeout: Tamoz::Telegram::Client::DOWNLOAD_READ_TIMEOUT_S }]],
                 calls
  end

  def test_a_failed_download_is_transient
    with_transport do |transport, server|
      server.script('getFile', body: { 'ok' => true, 'result' => { 'file_id' => 'D1',
                                                                   'file_path' => 'documents/gone.txt' } }, times: 1)
      server.script('gone.txt', status: 404, raw: 'missing', times: 1)

      assert_raises(Comms::TransientTransportError) { transport.fetch_attachment('D1', max_bytes: 100) }
    end
  end
end
