# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_checks'
require 'tmpdir'

# The talk eval's graders, pinned on goldens so a grader change is a visible decision.
# rubocop:disable Minitest/MultipleAssertions
class TalkChecksTest < Minitest::Test
  def norm(text) = TalkChecks.normalize(text)

  def assert_norm(expected, input, label)
    assert_equal expected, norm(input), label
  end

  def assert_audio_kinds(expected, bytes, message = nil)
    assert_equal expected, TalkChecks.audio_kinds(bytes), message
  end

  def write_bytes(directory, name, bytes)
    File.binwrite(File.join(directory, name), bytes)
  end

  def test_each_normalizer_step_has_a_golden
    assert_norm 'check pond 7', 'Heard: «Check pond seven.»', 'wrapper'
    assert_norm 'cafe ist', 'ＣＡＦＥ ｉｓｔ', 'nfkc and case'
    assert_norm '10 percent 28 degrees 6.1 milligrams per litre 4 parts per million 3 kilograms',
                '10% 28°C 6.1 mg/L 4 ppm 3 kg', 'units'
    assert_norm 'background', 'background', 'a unit inside a word stays'
    assert_norm 'open settings.yaml and harvest-plan.md', 'open settings dot yaml and harvest-plan dot md',
                'file names'
    assert_norm '21 100 6.1 -3 4200 3 21 7 21', 'twenty one, one hundred, six point one, minus 3, 4,200, ' \
                                                'third, twenty-first, 07, 21st', 'numbers'
    assert_norm 'at 6:10 at 6:10 at 7:30 6:10', 'at six ten, at 6.10, at seven thirty, 06:10', 'times'
    assert_norm 'pond 7 is fine 6.1 settings.yaml', 'Pond 7 is fine! (6.1) "settings.yaml".', 'punctuation'
    assert_norm 'it is do not i am', 'It’s don’t I’m', 'contractions'
    assert_norm 'so like this', 'um so uh like er this hmm', 'fillers'
    assert_norm 'a b', "  a \n\t b  ", 'whitespace'
  end

  def test_six_ten_stays_two_numbers_and_twenty_one_becomes_one
    assert_equal '6 10 ponds', norm('six ten ponds')
    assert_equal '4200 fish', norm('four thousand two hundred fish')
  end

  def test_wer_is_word_edits_over_reference_words
    assert_in_delta 0.0, TalkChecks.wer('Check pond seven.', 'check pond 7')
    assert_in_delta 0.25, TalkChecks.wer('what is pond seven', 'what is pond eleven')
    assert_in_delta 0.5, TalkChecks.wer('a b c d', 'a c')
    assert_in_delta 1.0, TalkChecks.wer('a b', 'x y')
  end

  def test_a_slot_is_a_contiguous_match_of_any_form
    assert TalkChecks.slot?(['6:10'], 'oxygen in pond 7 at six ten')
    assert TalkChecks.slot?(%w[21 21st], 'on the twenty first of October')
    refute TalkChecks.slot?(['7'], 'oxygen in pond 17'), 'a digit inside another number is not the slot'
    refute TalkChecks.slot?(['milligrams per litre'], 'milligrams of litre')
  end

  def test_answers_need_every_group_and_the_first_sentence_is_the_oracle
    assert TalkChecks.answer?([['21'], ['october']], 'Harvest is planned for 21 October.')
    refute TalkChecks.answer?([['21'], ['october']], 'Harvest is planned for 21 November.')
    assert_equal 'Pond 18 has 0.5 ppm ammonia.', TalkChecks.first_sentence('Pond 18 has 0.5 ppm ammonia. Pond 17 ...')
  end

  def test_unspeakables_catch_code_paths_links_digests_and_references
    assert_equal [], TalkChecks.unspeakables('Pond 7 is fine. The log is ponds.md.')
    assert_equal(5, [TalkChecks.unspeakables("```\nx\n```"), TalkChecks.unspeakables('see /Users/me/notes.md'),
                     TalkChecks.unspeakables('at https://example.org'), TalkChecks.unspeakables('id 3f9a2b7c1d0e4f55'),
                     TalkChecks.unspeakables('req_abc-1')].count { |hits| !hits.empty? })
  end

  def wav = "RIFF#{[36].pack('V')}WAVEfmt ".b + ("\x00".b * 24)

  def mpeg_frames = ("\xFF\xFB\x90\x00".b + ("\x00".b * 413)) * 2

  def test_the_retention_scan_finds_each_audio_header
    assert_audio_kinds(['wav'], "prefix#{wav}")
    assert_audio_kinds(['ogg'], "..OggS\x00\x02...".b)
    assert_audio_kinds(['id3'], "ID3\x04\x00 tag".b)
    assert_audio_kinds(['mpeg'], "noise#{mpeg_frames}".b)
    assert_empty TalkChecks.audio_kinds("\xFF\xFB\x90\x00".b + ("\x00".b * 100)), 'one frame header alone is not audio'
    assert_empty TalkChecks.audio_kinds('RIFF and WAVE written as words'.b)
  end

  def test_the_retention_scan_walks_the_runtime_and_ignores_random_bytes
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, 'attachments'))
      write_bytes(directory, 'runtime.sqlite3', Random.new(1).bytes(2 * 1024 * 1024))

      assert_empty TalkChecks.retention_hits(directory), '2 MB of random bytes is not audio'
      write_bytes(directory, 'attachments/.held', wav)
      write_bytes(directory, 'runtime.sqlite3-wal', "page#{mpeg_frames}")

      assert_equal ['attachments/.held: wav', 'runtime.sqlite3-wal: mpeg'], TalkChecks.retention_hits(directory).sort
    end
  end

  def test_the_key_scan_reports_responses_carrying_a_key
    bodies = ['{"ok":true}', 'Authorization echoed: sk-live-0123456789', 'clean']

    assert_equal ['response 1'], TalkChecks.key_hits(bodies, %w[sk-live-0123456789 short])
    assert_empty TalkChecks.key_hits(bodies, ['abc']), 'keys shorter than 8 characters are not scanned'
  end

  def test_wilson_interval_brackets_the_rate
    lower, upper = TalkChecks.wilson(5, 5)

    assert_in_delta 0.566, lower, 0.001
    assert_in_delta 1.0, upper, 0.001
    assert_equal [0.0, 1.0], TalkChecks.wilson(0, 0)
  end
end
# rubocop:enable Minitest/MultipleAssertions
