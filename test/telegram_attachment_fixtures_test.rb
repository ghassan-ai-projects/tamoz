# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_bot_api_fake'

class TelegramAttachmentFixturesTest < Minitest::Test
  DIRECTORY = File.expand_path('fixtures/telegram_attachments', __dir__)
  PINNED = {
    'arabic.txt' => 'c9369f1e3979f279e1522c9216025429cec6ce7b9ba123afdb140555153b9012',
    'injection.txt' => 'b5ff860a6f8d78ad5817f0738001fe942f561d7c44b2517315909a5fec99c701',
    'label.png' => 'cfcdbe0e7cf89447f18932bbc57547ee9bcaaff2f8f7d593fd104bbf71929d4f',
    'invoice.pdf' => 'd642a2c954b786fae450349817bc46219bdb2ed3aa77cb0f3fc6433c9182dd88',
    'invoice.png' => 'ab615670a4e2f1cf3334776b4882548dcab99a362ef82620847f4e3617aca9a9',
    'notes.txt' => '8153177be92dff30b19359aca2a267da69048bcd9ec2536428e5a1636da25939',
    'scanned.pdf' => '8e0cfbf3cedd0ef0765351c2158c44afc9845ade369354aaaf9bf852ea29843e',
    'scenarios.json' => 'b2075aeb175e360fb00336ab75a5c6b2ceb0b8880c47eeebf2439d6c1488a579',
    'voice.ogg' => 'd40cb90804f5f3c2e4a82731dfbacd3d96ed0c7c8af80b11ca7c6d59dc8bf0d1'
  }.freeze

  def test_every_fixture_is_pinned
    actual = Dir.children(DIRECTORY).sort.to_h do |name|
      [name, Digest::SHA256.file(File.join(DIRECTORY, name)).hexdigest]
    end

    assert_equal PINNED, actual
  end

  def test_every_scenario_names_a_fixture_that_exists
    cases = JSON.parse(File.read(File.join(DIRECTORY, 'scenarios.json'), encoding: Encoding::UTF_8))

    cases.each_value { |spec| assert_path_exists File.join(DIRECTORY, spec.fetch('file')), spec.inspect }
  end

  def test_the_fake_bot_api_serves_files_to_the_real_transport
    fake = TelegramBotApiFake.new
    client = Tamoz::Telegram::Client.new('123:eval', origin: fake.origin, read_timeout: 2.0)
    normalizer = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)
    transport = Tamoz::Telegram::Transport.new(client:, normalizer:)
    fake.send_document(1001, 'MARIGOLD', name: 'notes.txt', mime_type: 'text/plain')
    big = fake.send_document(1001, 'x', name: 'big.txt', mime_type: 'text/plain', announced: 25_000_000)
    attachment = transport.poll(next_offset: nil, limit: 10, timeout_s: 0)[:updates].first.fetch('attachment')

    assert_equal 'MARIGOLD', transport.fetch_attachment(attachment.fetch('file_id'), max_bytes: 100)
    assert_raises(Tamoz::Comms::ResponseTooLargeError) do
      transport.fetch_attachment(big.dig('message', 'document', 'file_id'), max_bytes: 30_000_000)
    end
    assert_raises(Tamoz::Comms::TransientTransportError) { transport.fetch_attachment('nope', max_bytes: 100) }
  ensure
    fake&.stop
  end
end
