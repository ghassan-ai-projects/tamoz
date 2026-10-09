# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_bot_api_fake'

class TelegramAttachmentFixturesTest < Minitest::Test
  DIRECTORY = File.expand_path('fixtures/telegram_attachments', __dir__)
  PINNED = {
    'injection.txt' => 'b5ff860a6f8d78ad5817f0738001fe942f561d7c44b2517315909a5fec99c701',
    'invoice.pdf' => 'd642a2c954b786fae450349817bc46219bdb2ed3aa77cb0f3fc6433c9182dd88',
    'invoice.png' => 'ab615670a4e2f1cf3334776b4882548dcab99a362ef82620847f4e3617aca9a9',
    'label.png' => 'cfcdbe0e7cf89447f18932bbc57547ee9bcaaff2f8f7d593fd104bbf71929d4f',
    'line_items.txt' => 'fa2f4d3bd08694b5ca6fd41027b7ca07e2901d82511ae124f5e0c6a4b8256b61',
    'long_report.txt' => 'b68cb3249fdfa07574c4399fe415077b0cf3d31c5b2169d6b2a7d480268c9c83',
    'meeting_notes.txt' => '57c89f7f2beeb5fa7cb16970e865a66e093f0c40bb6c0023c1c41c4a83ef8993',
    'notes.txt' => '8153177be92dff30b19359aca2a267da69048bcd9ec2536428e5a1636da25939',
    'over_cap.txt' => '31136cd653d04ca324c43da003ac38f8be1cdbc1ad9288afc51552f5faa21195',
    'parts_table.png' => 'f5a40232950aa92e9062a25290d4da72671665616dfef80fe7a013ad919a7feb',
    'receipt_photo.jpg' => 'ddbbe8d25ec44a7c3c428ee0dc0466e65c5383765ca41e7f78d6e421aeaafaa0',
    'report.pdf' => '7307f4e606327a520f2f596e5811cf017c1f0a8992b5867a0c77fbccb7c7404a',
    'scanned.pdf' => '8e0cfbf3cedd0ef0765351c2158c44afc9845ade369354aaaf9bf852ea29843e',
    'scenarios.json' => '42326819c7a02b32114c6fc0715bdc3ed083e96356d0814b47fc4ee40dbb6633',
    'voice_fact.ogg' => '15a8bd9505cfc493c5450fc3a4efa029e7797b9dc5a3102a4bff1f548f526a44',
    'voice_forwarded.ogg' => '019ece112d574763d16847675b198e56a54879c11bf02b8f56d07bbdb8515691',
    'voice_question.ogg' => '5b10f291ec87b2bd463f4e8a066e65e91e4e5a320d46c237d82fcebcfb9d4ae4'
  }.freeze

  def spec = JSON.parse(File.read(File.join(DIRECTORY, 'scenarios.json'), encoding: Encoding::UTF_8))

  def text_of(file) = File.read(File.join(DIRECTORY, file), encoding: Encoding::UTF_8)

  def test_every_fixture_is_pinned
    actual = Dir.children(DIRECTORY).sort.to_h do |name|
      [name, Digest::SHA256.file(File.join(DIRECTORY, name)).hexdigest]
    end

    assert_equal PINNED, actual
  end

  def test_every_scenario_is_complete_and_names_a_known_capability
    suite = spec.fetch('suite')

    spec.fetch('scenarios').each do |name, scenario|
      assert_path_exists File.join(DIRECTORY, scenario.fetch('file')), name
      assert_includes suite.fetch('capabilities'), scenario.fetch('needs'), name
      assert_predicate scenario.fetch('budget_s'), :positive?, name
      graded = %w[expect absent only_file_numbers forbidden_file reply_includes].any? { |key| scenario.key?(key) }

      assert graded, "#{name} grades nothing about the reply"
    end
  end

  def test_the_answer_a_text_scenario_expects_is_really_in_its_file
    spec.fetch('scenarios').each do |name, scenario|
      next unless scenario['mime_type'] == 'text/plain' && scenario['expect']
      next if scenario['expect'] == [['1320.00', '1320']]

      text = text_of(scenario.fetch('file'))

      scenario.fetch('expect').each { |alternatives| assert(alternatives.any? { |fact| text.include?(fact) }, name) }
    end
  end

  def test_the_needles_sit_where_the_scenarios_need_them
    limit = Tamoz::Agent::WorkAttachment::MAX_CHARACTERS

    assert_operator text_of('long_report.txt').index('KESTREL-8812'), :<, limit, 'readable: inside the cap'
    assert_operator text_of('over_cap.txt').index('SILVER-HALIBUT-31'), :>, limit, 'unreadable: past the cap'
    refute_match(/\d{3,}/, text_of('meeting_notes.txt').gsub(/\d{1,2} May/, ''), 'nothing a model could quote')
  end

  def test_the_line_items_add_up_to_the_expected_total
    amounts = text_of('line_items.txt').scan(/([\d,]+\.\d{2}) dollars/).flatten.map { |amount| amount.delete(',').to_f }

    assert_in_delta 1320.00, amounts.sum, 0.001
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

  def test_a_forwarded_voice_note_arrives_as_someone_elses_audio
    fake = TelegramBotApiFake.new
    normalizer = Tamoz::Telegram::Normalizer.new(surface_id: 'telegram-ops', surface_revision: 1)
    transport = Tamoz::Telegram::Transport.new(client: Tamoz::Telegram::Client.new('123:eval', origin: fake.origin),
                                               normalizer:)
    fake.send_voice(1001, 'OggS', duration: 3, forwarded: true)

    assert_equal 'audio',
                 transport.poll(next_offset: nil, limit: 1, timeout_s: 0)[:updates].first.dig('attachment', 'kind')
  ensure
    fake&.stop
  end
end
