# frozen_string_literal: true

# -- each test assembles a whole scripted turn.

require_relative 'test_helper'
require_relative 'support/work_loop_fixtures'

# FC3, part one: what the model has been shown, and who owns that claim. Every test here drives
# the real gate with a scripted provider, so it is plumbing evidence, never intelligence.
class WorkLoopObservationTest < Minitest::Test
  include WorkLoopFixtures

  FILES = { 'lib/value.rb' => "VALUE = 1\n" }.freeze
  BOGUS_DIGEST = Digest::SHA256.hexdigest('not the file')

  def run_turns(root, adapter, turns)
    model = ScriptedConversationModel.new(turns:)
    session = work_session(model:, root:, adapter:)
    [session.start('Set VALUE to 2', thread: 'work', request_id: 'work-1'), model]
  end

  def read_call(path) = ['read_file', { 'path' => path }]

  def test_a_patch_to_a_file_never_read_is_refused_not_observed
    with_work_workspace(files: FILES) do |root, adapter|
      turns = [{ calls: [plan_call] }, { calls: [patch_call(root, 'lib/value.rb', 'VALUE = 1', 'VALUE = 2')] },
               { content: 'Stopped.' }]
      outcome, model = run_turns(root, adapter, turns)

      assert_match(%r{Error \[not_observed\]: read lib/value\.rb first}, tool_results(model).last)
      assert_equal "VALUE = 1\n", File.read(File.join(root, 'lib/value.rb'))
      assert_empty outcome.state.fetch(:effect_intents, []),
                   'a refusal before approval must not journal an effect intent'
    end
  end

  def test_a_patch_after_an_external_change_is_refused_stale_file
    with_work_workspace(files: FILES) do |root, adapter|
      external = "VALUE = 1\n# someone else wrote this\n"
      turns = [{ calls: [plan_call] }, { calls: [read_call('lib/value.rb')] },
               lambda { |_|
                 File.write(File.join(root, 'lib/value.rb'), external)
                 { calls: [patch_call(root, 'lib/value.rb', 'VALUE = 1', 'VALUE = 2')] }
               }, { content: 'Stopped.' }]
      outcome, model = run_turns(root, adapter, turns)

      assert_match(%r{Error \[stale_file\]: lib/value\.rb changed since you last read it}, tool_results(model).last)
      assert_equal external, File.read(File.join(root, 'lib/value.rb')), 'the refusal must leave the file untouched'
      assert_empty outcome.state.fetch(:effect_intents, [])
    end
  end

  def test_a_second_patch_after_a_first_needs_no_re_read
    with_work_workspace(files: FILES) do |root, adapter|
      turns = [{ calls: [plan_call] }, { calls: [read_call('lib/value.rb')] },
               { calls: [patch_call(root, 'lib/value.rb', 'VALUE = 1', 'VALUE = 2')] },
               { calls: [patch_call(root, 'lib/value.rb', 'VALUE = 2', 'VALUE = 3')] },
               { content: 'Done.' }]
      _, model = run_turns(root, adapter, turns)
      results = tool_results(model)

      assert_equal "VALUE = 3\n", File.read(File.join(root, 'lib/value.rb'))
      assert_equal 4, results.length, 'plan, read and two patches'
      refute_match(/Error/, results.last)
    end
  end

  def test_the_ledger_pins_the_version_and_the_models_digest_is_ignored
    with_work_workspace(files: FILES) do |root, adapter|
      wrong = ['apply_patch', { 'path' => 'lib/value.rb', 'expected_sha256' => BOGUS_DIGEST,
                                'before' => 'VALUE = 1', 'after' => 'VALUE = 2' }]
      turns = [{ calls: [plan_call] }, { calls: [read_call('lib/value.rb')] }, { calls: [wrong] },
               { content: 'Done.' }]
      _, model = run_turns(root, adapter, turns)

      assert_equal "VALUE = 2\n", File.read(File.join(root, 'lib/value.rb')),
                   'the ledger version decides, not the digest the model sent'
      refute_match(/Error/, tool_results(model).last)
    end
  end

  def test_an_unranged_read_gets_the_default_window_and_is_never_spilled
    with_work_workspace(files: long_file(5_000)) do |root, adapter|
      turns = [{ calls: [plan_call] }, { calls: [read_call('lib/long.rb')] }, { content: 'Stopped.' }]
      outcome, model = run_turns(root, adapter, turns)
      result = tool_results(model).last

      assert_match(/lines: 1-800 of 5000/, result)
      assert_match(/continue with offset 801/, result)

      entry = outcome.state.fetch(:work_entries).find { |candidate| candidate['name'] == 'read_file' }

      refute(entry['spilled'], 'a read result is re-readable and never spilled')
    end
  end

  def test_a_pipeline_read_is_unchanged_by_the_work_window
    with_work_workspace(files: long_file(5_000)) do |root, _adapter|
      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true, checks: {})

      text = toolbox.execute('read_file', 'path' => 'lib/long.rb')

      refute_match(/truncated/, text)
      assert_equal 'line 5000', text.lines.last.chomp
    end
  end

  def long_file(lines)
    { 'lib/long.rb' => (1..lines).map { |number| "line #{number}\n" }.join }
  end
end
