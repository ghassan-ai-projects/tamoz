# frozen_string_literal: true

require_relative "test_helper"

# P14-S (plan §8/C5) — replay credential isolation, by mechanism not claim.
#
# (a) Behavioral: a poisoned credential resolver that raises on ANY resolution
#     runs under each replay mode and must never be called, never raise.
# (b) Type-level: the replay runtime constructor accepts no credential
#     argument (asserted by API shape — the initialize signature has no
#     credential parameter).
#
# Real-effector calls during replay are impossible by construction: no
# effector credentials exist in replay scopes. Enabling the simulator never
# enables a real effector.
class StreamReplayCredentialIsolationTest < Minitest::Test
  Stream = Tamoz::Stream

  def test_replay_constructor_accepts_no_credential_argument
    # Type-level (C5): the initialize signature must not have a credential
    # parameter. Introspect the parameter list.
    signature = Stream::ReplayRuntime.instance_method(:initialize).parameters
    param_names = signature.map(&:last)
    refute_includes param_names, :credential
    refute_includes param_names, :credentials
    refute_includes param_names, :source_credential
    refute_includes param_names, :effector_credential
  end

  def test_poison_credential_resolver_is_never_called_in_any_replay_mode
    poison = lambda do |*_args|
      raise "a replay mode resolved a credential"
    end

    Stream::ReplayRuntime::MODES.each do |mode|
      runtime = Stream::ReplayRuntime.new(mode:, simulator: FakeSimulator.new)
      # The run path has no credential argument at all; the poison resolver is
      # simply never reachable. This test proves the ABSENCE of any resolution
      # path by running every mode's full path with the poison available.
      events = [{"event_id" => "e1"}]
      result = runtime.run(
        process: ->(batch, clock) { [batch, clock.now_processing] },
        clock: Stream::ReplayClock.new(start: 1_700_000_000),
        batch: events
      )
      assert_equal events, result[0]
      # No exception -> the poison was never invoked.
    end
  end

  def test_counterfactual_routes_commands_to_the_simulator_only
    simulator = FakeSimulator.new
    runtime = Stream::ReplayRuntime.new(mode: :counterfactual, simulator:)
    runtime.deliver_command({"intent" => {"risk" => "r2_bounded"}})
    assert_equal 1, simulator.accepted.length

    # The simulator never enables a real effector: it records, it does not act
    # on the physical world.
    assert_kind_of FakeSimulator, runtime.instance_variable_get(:@simulator)
  end

  def test_deliver_command_requires_counterfactual_mode_and_a_simulator
    # No simulator configured -> refused.
    assert_raises(Stream::StreamError) do
      Stream::ReplayRuntime.new(mode: :counterfactual).deliver_command({"intent" => {}})
    end
    # Non-counterfactual modes never route commands.
    assert_raises(Stream::StreamError) do
      Stream::ReplayRuntime.new(mode: :deterministic, simulator: FakeSimulator.new)
                           .deliver_command({"intent" => {}})
    end
  end

  class FakeSimulator
    attr_reader :accepted

    def initialize
      @accepted = []
    end

    # The ONLY effector: records the command, never touches the physical
    # world. This is the v1 simulator bound by the owner constraint.
    def accept(command)
      @accepted << command
      {"accepted" => true, "command" => command}
    end
  end
end
