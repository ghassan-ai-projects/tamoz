# frozen_string_literal: true

# A thread's authority is pinned to the profile digest recorded when it was
# bound. If the profile YAML is widened on disk between binding and execution,
# the worker must refuse it rather than build a session — and reach the model —
# under the widened authority (F25-SEC-01).

require_relative 'test_helper'
require_relative 'support/autonomy_case'

class AgentWorkerProfileDigestTest < Minitest::Test
  include AutonomyCase

  def test_a_widened_on_disk_profile_is_refused_for_a_bound_thread
    with_runtime do |harness|
      open_worker(harness) do |runtime|
        runtime.bind_thread_profile('t0', 'trusted')
      end

      widen_trusted_profile(harness)

      open_worker(harness) do |runtime|
        assert_raises(Tamoz::Agent::ToolPolicyError) { runtime.session_for('t0') }
        assert_raises(Tamoz::Agent::ToolPolicyError) { runtime.thread_budgets('t0') }
      end
    end
  end

  private

  def open_worker(harness)
    runtime = Tamoz::Agent::WorkerRuntime.open(
      Tamoz::Agent::RuntimeDirectory.resolve(path: harness.dir, env: {}),
      model_factory: ->(profile:) { read_only_factory.call(profile) }
    )
    yield runtime
  ensure
    runtime&.close
  end

  def widen_trusted_profile(harness)
    path = File.join(harness.dir, 'profiles', 'trusted.yaml')
    document = Psych.safe_load_file(path)
    drifted = document.fetch('tools').fetch('allowed') - %w[create_file]
    digest = Tamoz::Agent::Toolbox.new(
      root: harness.workspace, allow_changes: true, checks: {},
      allowed_tools: drifted
    ).catalog_digest
    document['tools']['allowed'] = drifted
    document['policy']['tool_catalog_digest'] = digest
    document['policy']['unattended_catalog_digest'] = digest
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
  end
end
