# frozen_string_literal: true

require_relative 'test_helper'

class AgentImprovementLifecycleTest < Minitest::Test
  Improvement = Tamoz::Agent::Improvement
  Lifecycle = Improvement::CandidateLifecycle

  def setup
    @proposal = Lifecycle.propose(
      thread_id: 'thread-1', profile_id: 'profile-1',
      from_digest: digest('from'), to_digest: digest('candidate'),
      scope: 'config', created_by: 'agent'
    )
    @candidate = {
      'profile_id' => 'profile-1', 'digest' => @proposal.to_digest,
      'scope' => 'config', 'content' => { 'setting' => 'narrower' }
    }
    @runner = EffectRunner.new
    @lifecycle = Lifecycle.new(
      proposal: @proposal, candidate_resolver: ->(_digest) { @candidate },
      effect_runner: @runner, actor: 'operator'
    )
    @lifecycle.validate!
  end

  def test_approval_digest_binds_the_exact_candidate_and_actor
    request = @lifecycle.approval_request(actor: 'operator')

    assert_raises(Improvement::ApprovalDigestError) do
      @lifecycle.approve!(approval_digest: digest('wrong'), evidence: 'human:operator')
    end
    approval = @lifecycle.approve!(
      approval_digest: request.fetch('approval_digest'), evidence: 'human:operator'
    )

    assert_equal(
      {
        digest: request.fetch('approval_digest'), authority_digest: @proposal.from_digest,
        evidence: 'human:operator'
      },
      {
        digest: approval.digest, authority_digest: approval.authority_digest,
        evidence: approval.evidence
      }
    )
  end

  def test_crash_reconciliation_is_typed_unknown_and_blocks_following_phases
    approve
    @runner.next_status = :unknown

    result = @lifecycle.apply!(
      context: :context, perform: -> { flunk 'must not retry unknown apply' },
      reconcile: -> { :unknown }
    )

    assert_equal(
      { status: :unknown, phase: :unknown }, { status: result.status, phase: @lifecycle.phase }
    )
    assert_raises(Improvement::CandidateUnknownError) do
      @lifecycle.restart_health_verify!(context: :context, perform: -> {}, reconcile: -> { :unknown })
    end
  end

  def test_apply_and_restart_health_are_verified_as_separate_durable_effects
    result = apply_and_verify

    assert_predicate result, :succeeded?
    assert_equal(
      {
        phase: :verified, operations: %w[improvement.apply improvement.restart_health_verify],
        proposal_digest: @proposal.digest,
        approval_digests: @runner.requests.map { |request| request.fetch('approval_digest') }.uniq.length
      },
      {
        phase: @lifecycle.phase, operations: @runner.operations,
        proposal_digest: @runner.requests.first.fetch('proposal_digest'),
        approval_digests: @runner.requests.map { |request| request.fetch('approval_digest') }.uniq.length
      }
    )
  end

  def test_activate_and_rollback_are_separate_effects_with_fresh_approval
    apply_and_verify
    @lifecycle.activate!(context: :context, perform: -> { 'active' }, reconcile: -> { :completed })
    rollback_request = @lifecycle.approval_request(operation: :rollback, actor: 'operator')
    @lifecycle.approve!(
      operation: :rollback, approval_digest: rollback_request.fetch('approval_digest'),
      evidence: 'human:operator'
    )

    result = @lifecycle.rollback!(
      context: :context, perform: -> { 'rolled back' }, reconcile: -> { :completed }
    )

    assert_predicate result, :succeeded?
    assert_equal(
      {
        phase: :rolled_back,
        operations: %w[
          improvement.apply improvement.restart_health_verify improvement.activate improvement.rollback
        ]
      },
      { phase: @lifecycle.phase, operations: @runner.operations }
    )
  end

  def test_secret_and_authority_widening_candidates_are_rejected
    secret = @candidate.merge('content' => 'sk-live-secret-value')
    authority = @candidate.merge('grants_authority' => true)

    [secret, authority].each do |candidate|
      lifecycle = Lifecycle.new(
        proposal: @proposal, candidate_resolver: ->(_digest) { candidate }, effect_runner: @runner
      )
      assert_raises(Improvement::ImprovementPolicyError) { lifecycle.validate! }
    end
  end

  def test_candidate_content_is_revalidated_before_approval
    @candidate = @candidate.merge('content' => { 'setting' => 'changed-after-validation' })

    assert_raises(Improvement::EvaluatorTamperError) do
      @lifecycle.approval_request(actor: 'operator')
    end
  end

  private

  def approve
    request = @lifecycle.approval_request(actor: 'operator')
    @lifecycle.approve!(
      approval_digest: request.fetch('approval_digest'), evidence: 'human:operator'
    )
  end

  def apply_and_verify
    approve
    @lifecycle.apply!(context: :context, perform: -> { 'applied' }, reconcile: -> { :completed })
    @lifecycle.restart_health_verify!(
      context: :context, perform: -> { 'healthy' }, reconcile: -> { :completed }
    )
  end

  def digest(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end

  class EffectRunner
    Outcome = Data.define(:status, :value)

    attr_accessor :next_status
    attr_reader :operations, :requests

    def initialize
      @operations = []
      @requests = []
      @next_status = :succeeded
    end

    def run(operation:, request:, **_options)
      @operations << operation
      @requests << request
      value = yield if @next_status == :succeeded
      Outcome.new(status: @next_status, value:).freeze
    end
  end
end
