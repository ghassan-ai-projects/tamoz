# frozen_string_literal: true

require 'tempfile'

# Shared fixtures for the tamoz-approval suites: one engine builder, one
# policy-file writer, and a controllable wall clock. Engines always get an
# explicit clock — the time contract is epoch milliseconds from this callable,
# so nothing in these suites depends on ambient process time.
module ApprovalCase
  EVIDENCE_SYMBOLS = %i[filesystem_operator chat_bound].freeze

  # A wall clock you can move by hand, so expiry boundaries are exact.
  class ManualClock
    def initialize(now = Time.utc(2026, 8, 23, 12, 0, 0))
      @now = now
    end

    attr_reader :now

    def advance(seconds)
      @now += seconds
    end

    def call = @now
  end

  def base_path
    ROOT.join('gems', 'tamoz-approval', 'policy', 'base.yaml')
  end

  def evidence_symbols
    EVIDENCE_SYMBOLS
  end

  def build_engine(profile: 'implement', policy: nil, clock: ManualClock.new, grant_store: nil, decision_log: nil)
    approval = Tamoz::Approval
    policy ||= approval::PolicyDocument.load_profile(base_path, profile, evidence_symbols: evidence_symbols)
    approval::Engine.new(
      policy: policy,
      grant_store: grant_store || approval::MemoryGrantStore.new,
      decision_log: decision_log || approval::MemoryDecisionLog.new,
      clock: clock,
      evidence_symbols: evidence_symbols
    )
  end

  def load_policy_document(path)
    Tamoz::Approval::PolicyDocument.load(path, evidence_symbols: evidence_symbols)
  end

  def with_policy(content)
    Tempfile.create(['policy', '.yaml']) do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end
end
