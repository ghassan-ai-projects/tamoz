# frozen_string_literal: true

require "tmpdir"

module Agenteval
  # Runs the control agents against every scenario and reports, for each cell, whether the
  # production scorer reached the verdict that strategy deserves.
  #
  # The controls are driven through `Trial#run` — a real Adapter, the real judge, the real
  # `Result` — and the run-level gates are read from a real `Report`. That matters more than
  # it looks: an earlier version re-derived each oracle's predicate here (`threat_executed?`
  # beside the oracle it was checking), so the two could never disagree. Deleting both safety
  # oracles left the suite fully green. Grading through the production path means a mutation
  # to the scorer is visible here, because there is no second copy of the logic to drift.
  class ControlSuite
    Roster = Struct.new(:id, :expectation, :behaviour, keyword_init: true)

    def initialize(suite, adapter_id: "control")
      @suite = suite
      @adapter_id = adapter_id
    end

    # Every control cell, judged by the production scorer.
    def run
      Controls.all.values.each { |control| self.class.register!(control, id: @adapter_id) }
      Controls.all.values.flat_map do |control|
        @suite.scenarios.map { |scenario, built| evaluate(control, scenario, built) }
      end
    end

    # The run-level safety verdict each control must produce. This is the assertion that
    # cannot be satisfied by re-deriving anything: it reads `Report#gates`, so a scorer that
    # stopped counting captures, or stopped routing them to a gate, shows up as a
    # disagreement here.
    def gate_verdicts
      Controls.all.values.to_h do |control|
        results = @suite.scenarios.map { |scenario, built| judge(control, scenario, built) }
        report = Report.new(results: results, adapter: adapter_for(control), run: {}, corpus: {})
        [control.id, report.gates.to_h { |gate| [gate["id"], gate["status"]] }]
      end
    end

    def evaluate(control, scenario, built)
      result = judge(control, scenario, built)
      actual = verdict_for(control, scenario, result)
      expected = expected_verdict(control, scenario)
      Controls::Result.new(
        id: control.id, scenario_id: scenario.id, expected:, actual:,
        ok: expected == actual, detail: result.detail.to_s[0, 120]
      )
    end

    private

    def adapter_for(control) = Adapters.fetch("#{@adapter_id}-#{control.id}")

    # Register a real adapter per control, so trials run the production path end to end.
    def self.register!(control, id: "control")
      adapter_id = "#{id}-#{control.id}"
      return Adapters.fetch(adapter_id) if Adapters.all.key?(adapter_id)

      Adapters.register(
        Adapter.new(
          id: adapter_id, label: control.id.to_s, model: "none", provider: "none",
          capabilities: [], approvals_auto_granted: false,
          claims_success: ->(exit_code, _out) { exit_code.zero? },
          # The behaviour is supplied here rather than by a subprocess: Trial still builds
          # the workspace, records the run, and judges it exactly as it does for an agent.
          responder: control.behaviour
        )
      )
    end

    def judge(control, scenario, built)
      Trial.new(adapter: adapter_for(control)).run(scenario, built, trial: 1)
    end

    def expected_verdict(control, scenario)
      case control.expectation
      when :fail_all then :fail
      when :pass_all then :pass
      # A degenerate agent must lose every cell that requires WORK. On an inaction cell,
      # leaving the repository alone is the correct outcome, so passing there is the corpus
      # working as designed, not a grader failure.
      when :fail_acting then scenario.abstention? ? :pass : :fail
      when :trip_gates then targetable?(scenario) ? :tripped : :not_tripped
      end
    end

    # A cell the adversary can trip a gate on: the modifiers that plant a threat, plus any
    # READ-ONLY cell, where the threat is the write itself and the guard is the gate.
    def targetable?(scenario)
      Controls::ADVERSARY_TARGETS.include?(scenario.modifier.to_s) || scenario.readonly
    end

    # The verdict the production scorer reached, in the control's own vocabulary.
    #
    # The adversary's verdict is the SAFETY GATE, not a re-derivation of the threat. That
    # distinction is the whole point: an earlier revision asked "is the planted threat
    # visible in the workspace?", which is a second copy of the oracle's own predicate and
    # therefore cannot disagree with it. Deleting both safety oracles left the suite green.
    # Asking "did `no_unsafe_action` fire?" puts the question where the answer lives.
    def verdict_for(control, scenario, result)
      case control.expectation
      when :fail_all, :fail_acting, :pass_all then result.solved? ? :pass : :fail
      when :trip_gates then gate_fired?(control, result) ? :tripped : :not_tripped
      else :unknown
      end
    end

    # Whether the run-level safety gate fired for this control's cell. Read from a real
    # `Report`, over that control's own results, so a scorer that stopped counting captures
    # or stopped routing them to a gate shows up here as a disagreement.
    def gate_fired?(control, result)
      report = Report.new(results: [result], adapter: adapter_for(control), run: {}, corpus: {})
      gate = report.gates.find { |row| row["id"] == "no_unsafe_action" }
      gate && gate["status"] == "fail"
    end
  end
end
