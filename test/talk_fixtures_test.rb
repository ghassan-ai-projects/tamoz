# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_checks'
require 'digest'

# The talk eval's corpus is data: pinned, split by script, and every slot findable in its own script.
# rubocop:disable Minitest/MultipleAssertions
class TalkFixturesTest < Minitest::Test
  SPLITS = %w[dev held_out].freeze
  SPEC_DIGEST = '20d74c9955714d6adac40a6e49a34f8c2d46c9d4ba0b9c5c1d6bf4bf6dffdf5b'
  WAV_DIR = File.expand_path('fixtures/talk/wav', __dir__)

  def spec = TalkChecks.spec

  def scripts = spec.fetch('scripts').to_h { |script| [script.fetch('id'), script] }

  def test_the_scenarios_file_changes_only_as_a_reviewed_update
    assert_equal SPEC_DIGEST, Digest::SHA256.file(TalkChecks::SPEC_PATH).hexdigest
  end

  def script_ids = spec.fetch('scripts').map { |script| script.fetch('id') }

  def split_of(script) = script.fetch('split')

  def heard_scripts = scripts.values.select { |script| script.fetch('id').start_with?('h') }

  def heard_slot_total
    heard_scripts.sum { |script| script.fetch('slots').length } * spec.dig('suite', 'voices').length
  end

  def splits_known? = scripts.values.all? { |script| SPLITS.include?(split_of(script)) }

  def dev_script_count = scripts.values.count { |script| split_of(script) == 'dev' }

  def heard_held_out? = heard_scripts.all? { |script| split_of(script) == 'held_out' }

  def heard_clean_rules = spec.dig('scenarios', 'heard_clean')

  def used_script_ids = JSON.generate(spec.fetch('scenarios')).scan(/"([a-z]\d\d)"/).flatten.uniq

  def each_slot(&)
    scripts.each_value { |script| script.fetch('slots').each { |forms| yield script, forms } }
  end

  def pinned_digests = JSON.parse(File.read(File.expand_path('fixtures/talk/digests.json', __dir__)))

  def assert_recording_matches_its_pin(pinned, path)
    bytes = File.binread(path)

    assert_equal pinned.fetch(File.basename(path)), Digest::SHA256.hexdigest(bytes)
    assert_equal [1, 1, 16_000, 16], bytes.byteslice(20, 16).unpack('vvVx6v'), 'PCM, mono, 16 kHz, 16-bit'
  end

  def test_scripts_are_split_by_id_and_large_enough
    assert_equal script_ids.uniq, script_ids
    assert_predicate self, :splits_known?
    assert_operator dev_script_count, :>=, 6
    assert_predicate self, :heard_held_out?
    assert_operator heard_scripts.length, :>=, heard_clean_rules.fetch('min_scripts')
    assert_operator heard_slot_total, :>=, heard_clean_rules.fetch('min_slots')
  end

  def test_every_slot_is_found_in_its_own_script_and_no_scenario_uses_a_dev_script
    each_slot do |script, forms|
      assert TalkChecks.slot?(forms, script.fetch('text')), "#{script['id']}: #{forms.inspect}"
    end

    assert_empty used_script_ids - scripts.keys, 'every referenced script exists'
    assert(used_script_ids.none? { |id| split_of(scripts.fetch(id)) == 'dev' })
  end

  def test_the_committed_recordings_match_their_pinned_digests
    pinned = pinned_digests
    files = Dir[File.join(WAV_DIR, '*.wav')]

    assert_equal(pinned.keys.sort, files.map { |path| File.basename(path) })
    assert_operator files.length, :<=, 12
    assert_operator files.sum { |path| File.size(path) }, :<=, 1_500_000
    files.each { |path| assert_recording_matches_its_pin(pinned, path) }
  end
end
# rubocop:enable Minitest/MultipleAssertions
