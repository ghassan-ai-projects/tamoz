# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_checks'
require 'digest'

# The talk eval's corpus is data: pinned, split by script, and every slot findable in its own script.
# rubocop:disable Minitest/MultipleAssertions
class TalkFixturesTest < Minitest::Test
  SPEC_DIGEST = 'c5357408d056e45d92454259911016513882770a84dca4d7ce32e1fa6dcc78d5'
  WAV_DIR = File.expand_path('fixtures/talk/wav', __dir__)

  def spec = TalkChecks.spec

  def scripts = spec.fetch('scripts').to_h { |script| [script.fetch('id'), script] }

  def test_the_scenarios_file_changes_only_as_a_reviewed_update
    assert_equal SPEC_DIGEST, Digest::SHA256.file(TalkChecks::SPEC_PATH).hexdigest
  end

  def test_scripts_are_split_by_id_and_large_enough
    ids = spec.fetch('scripts').map { |script| script.fetch('id') }
    heard = scripts.values.select { |script| script.fetch('id').start_with?('h') }
    voices = spec.dig('suite', 'voices').length

    assert_equal ids.uniq, ids
    assert(scripts.values.all? { |script| %w[dev held_out].include?(script.fetch('split')) })
    assert_operator scripts.values.count { |script| script.fetch('split') == 'dev' }, :>=, 6
    assert(heard.all? { |script| script.fetch('split') == 'held_out' })
    assert_operator heard.length, :>=, spec.dig('scenarios', 'heard_clean', 'min_scripts')
    assert_operator heard.sum { |script| script.fetch('slots').length } * voices, :>=,
                    spec.dig('scenarios', 'heard_clean', 'min_slots')
  end

  def test_every_slot_is_found_in_its_own_script_and_no_scenario_uses_a_dev_script
    scripts.each_value do |script|
      script.fetch('slots').each do |forms|
        assert TalkChecks.slot?(forms, script.fetch('text')), "#{script['id']}: #{forms.inspect}"
      end
    end
    used = JSON.generate(spec.fetch('scenarios')).scan(/"([a-z]\d\d)"/).flatten.uniq

    assert_empty used - scripts.keys, 'every referenced script exists'
    assert(used.none? { |id| scripts.fetch(id).fetch('split') == 'dev' })
  end

  def test_the_committed_recordings_match_their_pinned_digests
    pinned = JSON.parse(File.read(File.expand_path('fixtures/talk/digests.json', __dir__)))
    files = Dir[File.join(WAV_DIR, '*.wav')].sort

    assert_equal(pinned.keys.sort, files.map { |path| File.basename(path) })
    assert_operator files.length, :<=, 12
    assert_operator files.sum { |path| File.size(path) }, :<=, 1_500_000
    files.each do |path|
      bytes = File.binread(path)

      assert_equal pinned.fetch(File.basename(path)), Digest::SHA256.hexdigest(bytes)
      assert_equal [1, 1, 16_000, 16], bytes.byteslice(20, 16).unpack('vvVx6v'), 'PCM, mono, 16 kHz, 16-bit'
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
