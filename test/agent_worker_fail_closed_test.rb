# frozen_string_literal: true

# The durable gates fail CLOSED when the store cannot answer.
#
# What these read is the DIRECTION of the failure, which is the whole point.
# Every method exercised here used to rescue `StandardError` and return the
# permissive answer: zero spend, no budget, no recorded decision, no bound
# profile. That converts "the store is sick" — exactly when a ceiling matters
# — into "this thread has spent nothing and is under no ceiling".

require_relative 'test_helper'
require_relative 'support/autonomy_case'

class AgentWorkerFailClosedTest < Minitest::Test
  include AutonomyCase

  def with_broken_store(harness)
    runtime = Tamoz::Agent::WorkerRuntime.open(
      Tamoz::Agent::RuntimeDirectory.resolve(path: harness.dir, env: {}),
      model_factory: ->(profile:) { read_only_factory.call(profile) }
    )
    adapter = runtime.adapter
    adapter.define_singleton_method(:store) { raise IOError, 'the disk went away' }
    yield runtime
  ensure
    runtime&.close
  end

  def test_a_sick_store_never_reports_a_thread_as_having_spent_nothing
    with_runtime do |harness|
      with_broken_store(harness) do |runtime|
        error = assert_raises(Tamoz::Agent::WorkerRuntime::StoreUnavailableError) do
          runtime.occurrence_age_seconds('t0')
        end
        assert_match(/is unavailable.*the disk went away/, error.message)
        assert_kind_of IOError, error.cause, 'the cause is kept, not flattened'
      end
    end
  end

  def test_a_sick_store_never_reports_a_thread_as_unbudgeted_or_unbound
    with_runtime do |harness|
      with_broken_store(harness) do |runtime|
        assert_raises(Tamoz::Agent::WorkerRuntime::StoreUnavailableError) { runtime.thread_profile('t0') }
        assert_raises(Tamoz::Agent::WorkerRuntime::StoreUnavailableError) { runtime.thread_budgets('t0') }
      end
    end
  end

  # A recorded human approval that cannot be read is not "no answer yet". The
  # old `nil` left the work parked forever with nothing said anywhere.
  def test_a_sick_store_never_reports_a_recorded_decision_as_absent
    with_runtime do |harness|
      with_broken_store(harness) do |runtime|
        assert_raises(Tamoz::Agent::WorkerRuntime::StoreUnavailableError) do
          runtime.pending_decision('t0', 'r0', interrupt_digest: '0' * 64,
                                               now: Time.now.utc)
        end
      end
    end
  end

  def test_a_sick_store_never_reports_an_empty_work_list
    with_runtime do |harness|
      with_broken_store(harness) do |runtime|
        assert_raises(Tamoz::Agent::WorkerRuntime::StoreUnavailableError) { runtime.open_occurrences }
      end
    end
  end

  # A configuration mistake keeps its own identity: an unknown profile is a
  # permanent operator error, not a transient store failure, and the two must
  # not be reported as the same thing.
  def test_an_unknown_profile_is_still_a_configuration_error
    with_runtime do |harness|
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: harness.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        error = assert_raises(Tamoz::Agent::WorkerRuntime::Error) { runtime.profile('nope') }
        refute_kind_of Tamoz::Agent::WorkerRuntime::StoreUnavailableError, error
      ensure
        runtime.close
      end
    end
  end
end
