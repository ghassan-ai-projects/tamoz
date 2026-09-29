# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/subagent_fixtures'

class SubagentConfigurationTest < Minitest::Test
  include SubagentFixtures

  def test_cli_accepts_only_shipped_roles
    parser = Tamoz::Agent::CLI::ArgumentParser.new(out: StringIO.new,
                                                   subcommands: Tamoz::Agent::CLI::SUBCOMMANDS)

    options, = parser.parse(%w[--subagents explore,explore code task])

    assert_equal ['explore'], options.fetch(:subagents)

    error = assert_raises(OptionParser::InvalidArgument) do
      parser.parse(%w[--subagents unknown code task])
    end
    assert_match(/unknown subagent role/, error.message)
  end

  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions -- one pinned-thread lifecycle
  def test_the_cli_refuses_subagents_it_would_ignore
    Dir.mktmpdir('tamoz-subagent-cli') do |sessions|
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})
      options = { session_dir: sessions, root: sessions }

      assert_raises(OptionParser::InvalidArgument) { cli.send(:work_harness, options.merge(subagents: %w[explore]), 't1') }
      assert_equal %w[explore], cli.send(:work_harness, options.merge(work_routing: true, subagents: %w[explore]), 't2')
                                   .fetch(:subagents)
      assert_equal %w[explore], cli.send(:work_harness, options.merge(work_routing: true), 't2').fetch(:subagents)
      assert_raises(OptionParser::InvalidArgument) { cli.send(:work_harness, options.merge(subagents: %w[explore]), 't3') }
      cli.send(:work_harness, options.merge(work_routing: true), 't4')
      assert_raises(OptionParser::InvalidArgument) do
        cli.send(:work_harness, options.merge(work_routing: true, subagents: %w[explore]), 't4')
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  def test_runtime_directory_validates_and_loads_roles
    with_directory do |runtime, document, config|
      directory = Tamoz::Agent::RuntimeDirectory.new(runtime)

      assert_empty directory.subagents

      document['harness'] = { 'subagents' => ['explore'] }
      File.write(config, Psych.dump(document))

      assert_equal ['explore'], Tamoz::Agent::RuntimeDirectory.new(runtime).subagents
    end
  end

  def test_runtime_directory_refuses_unknown_role
    with_directory do |runtime, document, config|
      document['harness'] = { 'subagents' => ['unknown'] }
      File.write(config, Psych.dump(document))

      error = assert_raises(Tamoz::Agent::RuntimeDirectory::Error) do
        Tamoz::Agent::RuntimeDirectory.new(runtime)
      end
      assert_match(/unknown subagent role/, error.message)
    end
  end

  # rubocop:disable Metrics/AbcSize -- one integration checks both precedence paths against real model headers.
  def test_worker_uses_directory_roles_and_an_explicit_override
    with_directory do |runtime, document, config|
      document['harness'] = { 'subagents' => ['explore'] }
      File.write(config, Psych.dump(document))
      directory = Tamoz::Agent::RuntimeDirectory.new(runtime)
      model = ScriptedTeam.new(parent: delegate_once, child: HAPPY_CHILD)
      worker = Tamoz::Agent::WorkerRuntime.open(directory, model_factory: ->(**) { model }, routing: :work)
      outcome = worker.send(:build_session, nil).start(TASK, thread: 'worker', request_id: 'w1')

      assert_equal :completed, outcome.status
      refute_empty model.child_requests

      plain = ScriptedTeam.new(parent: [{ content: 'No delegation.' }])
      disabled = Tamoz::Agent::WorkerRuntime.open(directory, model_factory: ->(**) { plain }, routing: :work,
                                                             harness: { 'subagents' => [] })
      disabled.send(:build_session, nil).start(TASK, thread: 'disabled', request_id: 'w2')

      refute_includes wire_names(plain.requests.first), 'delegate'
    ensure
      worker&.close
      disabled&.close
    end
  end
  # rubocop:enable Metrics/AbcSize

  private

  def with_directory
    Dir.mktmpdir('tamoz-subagent-config') do |root|
      runtime = File.join(root, 'runtime')
      Tamoz::Agent::RuntimeDirectory.create!(runtime, workspace: root)
      config = File.join(runtime, 'config.yaml')
      yield runtime, Psych.safe_load_file(config), config
    end
  end
end
