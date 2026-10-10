# frozen_string_literal: true

require_relative 'test_helper'
require 'ripper'

class ChannelKindContainmentTest < Minitest::Test
  WORDS = %w[telegram talk tg tk].freeze
  NAMED = %i[on_ident on_const on_tstring_content on_label on_ivar on_cvar on_gvar].freeze
  OWNERS = %w[gems/tamoz-telegram/ gems/tamoz-talk/ gems/tamoz-agent-cli/lib/tamoz/agent/channel_kinds.rb].freeze

  # Each count only falls, in the commit that removes the mention. The last five files are frozen by design:
  # checksummed migrations, benchmark-protocol code (ADR-058), and the stream's escalation default.
  EXPECTED = {
    'gems/tamoz-comms/lib/tamoz/comms/decision_record.rb' => 4,
    'gems/tamoz-comms/lib/tamoz/comms/parties.rb' => 18,
    'gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb' => 18,
    'gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb' => 11,
    'gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/readiness.rb' => 1,
    'gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb' => 6,
    'gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb' => 1
  }.freeze

  def self.parts(text)
    text.split(/[^A-Za-z0-9]+/)
        .flat_map { |word| word.split(/(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/) }
        .map(&:downcase)
  end

  def self.mentions(source)
    Ripper.lex(source).sum do |(_position, type, token, _state)|
      NAMED.include?(type) ? parts(token).count { |part| WORDS.include?(part) } : 0
    end
  end

  def test_a_channel_kind_is_named_only_where_its_count_says
    actual = Dir[ROOT.join('gems/*/lib/**/*.rb')].filter_map do |path|
      relative = Pathname(path).relative_path_from(ROOT).to_s
      next if relative.start_with?(*OWNERS)

      count = self.class.mentions(File.read(path, encoding: 'UTF-8'))
      [relative, count] if count.positive?
    end.to_h

    assert_equal EXPECTED, actual
  end

  def test_compound_names_strings_and_symbols_each_count_once
    {
      'talk_hub = 1' => 1, 'CLITalkCommands' => 1, "x = 'TAMOZ_TALK_TOKEN'" => 1, "k = 'telegram_user'" => 1,
      'k = :talk' => 1, 'p = "tg."' => 1, '@talk_hubs = {}' => 1, 'TamozTelegramBot = 1' => 1
    }.each { |source, expected| assert_equal expected, self.class.mentions(source), source }
  end

  def test_comments_and_unrelated_words_do_not_count
    { '# talk to telegram' => 0, "x = 'talked'" => 0, 'stack = 1' => 0, 'tkinter = 1' => 0 }
      .each { |source, expected| assert_equal expected, self.class.mentions(source), source }
  end
end
