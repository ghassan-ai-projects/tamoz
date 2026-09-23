# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/work_loop_fixtures'

class CliCodeTest < Minitest::Test
  include WorkLoopFixtures

  def code(argv, workspace:, factory:, extra: [], sessions: nil)
    return run_code(argv, workspace:, factory:, extra:, sessions:) if sessions

    Dir.mktmpdir('tamoz-cli-code') do |directory|
      FileUtils.chmod(0o700, directory)
      run_code(argv, workspace:, factory:, extra:, sessions: directory)
    end
  end

  def run_code(argv, workspace:, factory:, extra:, sessions:)
    out = StringIO.new
    err = StringIO.new
    global = ['--session-dir', sessions, '--root', workspace, *extra, '--check', 'test=true']
    status = Tamoz::Agent::CLI.run(global + argv, out:, err:, input: StringIO.new("y\n" * 20), env: {},
                                                  model_factory: factory)
    [status, out.string, err.string]
  end

  def with_sessions
    Dir.mktmpdir('tamoz-cli-code') do |directory|
      FileUtils.chmod(0o700, directory)
      yield directory
    end
  end

  def test_guidance_reaches_the_first_request_and_is_pinned_for_a_follow_up
    with_work_workspace(files: { 'AGENTS.md' => "Marker-5c1d: use tabs.\n" }) do |root, _|
      model = ScriptedConversationModel.new(turns: [{ content: 'First.' }, { content: 'Second.' }])
      with_sessions do |sessions|
        code(%w[--session t code first], workspace: root, factory: ->(_) { model }, sessions:,
                                         extra: %w[--allow-changes --guidance AGENTS.md])
        code(%w[--session t code second], workspace: root, factory: ->(_) { model }, sessions:,
                                          extra: %w[--allow-changes])

        assert(model.requests.all? { |request| request.include?('Marker-5c1d') })
      end
    end
  end

  def test_code_refuses_a_thread_that_is_not_a_work_thread
    with_work_workspace do |root, _|
      with_sessions do |sessions|
        File.write(File.join(sessions, 'legacy.sqlite3'), '')
        status, _, err = code(%w[--session legacy code more], workspace: root, sessions:,
                                                              factory: ->(_) { raise 'must not build' },
                                                              extra: %w[--allow-changes])

        refute_equal 0, status
        assert_match(/not a work thread/, err)
      end
    end
  end

  def test_a_missing_guidance_file_is_refused
    with_work_workspace do |root, _|
      status, _, err = code(%w[code anything], workspace: root, factory: lambda { |_|
        ScriptedConversationModel.new(turns: [])
      },
                                               extra: %w[--allow-changes --guidance NOPE.md])

      refute_equal 0, status
      assert_match(/NOPE.md/, err)
    end
  end

  def test_code_runs_the_work_loop_and_exits_zero_on_a_verified_change
    with_work_workspace(files: { 'lib/value.rb' => "VALUE = 1\n" }) do |root, _|
      model = ScriptedConversationModel.new(turns: [
        { calls: [plan_call] }, { calls: [read_call('lib/value.rb')] },
        ->(_) { { calls: [patch_call(root, 'lib/value.rb', 'VALUE = 1', 'VALUE = 2')] } },
        { calls: [['run_check', { 'name' => 'test' }]] }, { content: 'Changed lib/value.rb; test passed.' }
      ])
      status, out, err = code(['code', 'Set VALUE to 2'], workspace: root, factory: ->(_) { model },
                                                          extra: %w[--allow-changes])

      assert_equal 0, status, err
      assert_includes out + err, 'Changed lib/value.rb; test passed.'
      assert_equal "VALUE = 2\n", File.read(File.join(root, 'lib/value.rb'))
    end
  end

  def test_code_without_permission_to_change_is_refused
    with_work_workspace do |root, _|
      status, _, err = code(%w[code anything], workspace: root, factory: ->(_) { raise 'must not build' })

      refute_equal 0, status
      assert_match(/--allow-changes/, err)
    end
  end
end
