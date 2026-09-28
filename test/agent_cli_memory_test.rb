# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require_relative 'support/work_loop_fixtures'
require_relative 'support/memory_spec'

# Quality-bar row E5: the CLI opens memory only when the runtime directory enables it, in
# one file per session directory, shared by the threads there. Scripted model: plumbing only.
class AgentCliMemoryTest < Minitest::Test
  include AutonomyCase
  include WorkLoopFixtures
  include MemorySpec

  SAID = 'our tests live under verify/ and are named check_<name>.rb'

  def enable_memory(runtime)
    path = File.join(runtime.dir, 'config.yaml')
    document = Psych.safe_load_file(path)
    document['sources'] = { 'memory' => { 'enabled' => true, 'tenant' => 'acme', 'owner' => 'alice' } }
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end

  def code(runtime, session_dir, session, task, model)
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(
      ['--runtime-dir', runtime.dir, '--session-dir', session_dir, '--root', runtime.workspace, '--session', session,
       '--allow-changes', '--check', 'test=true', 'code', task],
      out: StringIO.new, err:, input: StringIO.new, env: {}, model_factory: ->(_options) { model }
    )
    [status, err.string]
  end

  def test_e5_threads_in_one_session_directory_share_memory_only_when_enabled
    spec_row('E5') do
      with_runtime do |runtime|
        session_dir = File.join(runtime.dir, 'sessions')
        first = ScriptedConversationModel.new(turns: [{ calls: [['remember', { 'quote' => SAID }]] },
                                                      { content: 'Noted.' }])
        second = ScriptedConversationModel.new(turns: [{ content: 'Ok.' }])

        code(runtime, session_dir, 'off', "Remember this: #{SAID}.", ScriptedConversationModel.new(turns: [
          { content: 'Ok.' }
        ]))

        refute_path_exists File.join(session_dir, 'memory.sqlite3')

        enable_memory(runtime)
        status, err = code(runtime, session_dir, 'one', "Remember this: #{SAID}.", first)

        assert_includes [0, 2], status, err
        code(runtime, session_dir, 'two', 'Add a test for slugify.', second)

        assert_path_exists File.join(session_dir, 'memory.sqlite3')
        assert_match(/Remembered mem\./, tool_results(first).first)
        assert_includes second.requests.first, SAID
      end
    end
  end

  def memory_cli(runtime, session_dir, *args, model: nil)
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime.dir, '--session-dir', session_dir, '--root',
                                    runtime.workspace, 'memory', *args],
                                   out:, err:, input: StringIO.new, env: {}, model_factory: ->(_options) { model })
    [status, out.string, err.string]
  end

  def test_operator_lists_forgets_and_consolidates
    with_runtime do |runtime|
      enable_memory(runtime)
      session_dir = File.join(runtime.dir, 'sessions')
      FileUtils.mkdir_p(session_dir, mode: 0o700)
      engine, adapter = memory_engine_at(session_dir, clock: -> { Time.now })
      project = Tamoz::Agent::Memory::Surface.project_scope(runtime.workspace)
      %w[s1 s2].each do |session|
        work_episode(engine, task: "flaky clock test fixed by freezing time in #{session}", outcome: 'done',
                             project:, session:)
      end
      adapter.close
      model = Class.new do
        def generate(prompt:, **)
          refs = JSON.parse(prompt).fetch('consolidation_input').map { |entry| entry.fetch('memory_id') }
          JSON.generate('statement' => "Freeze time in flaky tests (#{refs.length} episodes)",
                        'epistemic_kind' => 'reported', 'confidence' => 0.8, 'contradictions' => [],
                        'preserved_source_refs' => @refs)
        end
        attr_writer :refs
      end.new

      status, listed, = memory_cli(runtime, session_dir, 'list', 'freezing')

      assert_equal 0, status
      ids = listed.lines.map { |line| line.split.first }

      assert_equal 2, ids.length

      engine, adapter = memory_engine_at(session_dir, clock: -> { Time.now })
      records = ids.map { |id| engine.store.get(engine.namespace, "experience/#{id}").value }
      model.refs = records.sort_by(&:memory_id).map(&:digest)
      adapter.close
      status, consolidated, err = memory_cli(runtime, session_dir, 'consolidate', model:)

      assert_equal 0, status, err
      knowledge = JSON.parse(consolidated).fetch('results').first.fetch('knowledge')

      status, = memory_cli(runtime, session_dir, 'forget', ids.first)

      assert_equal 0, status
      _, after, = memory_cli(runtime, session_dir, 'list', 'freezing')

      refute_includes after, ids.first
      refute_includes after, knowledge
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Minitest/MultipleAssertions
