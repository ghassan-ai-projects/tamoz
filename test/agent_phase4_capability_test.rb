# frozen_string_literal: true

require_relative 'test_helper'

class AgentPhase4CapabilityTest < Minitest::Test
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions -- cross-seam assertions intentionally cover the full contract.
  class ChildRuntime
    attr_reader :child

    attr_accessor :child_delegation_context

    def enqueue_child_task(child, parent_profile:)
      @child = [child, parent_profile]
      child
    end
  end

  ProfileStub = Data.define(:profile_id, :tools_allowed, :canonical_digest)

  def test_delegation_is_a_sealed_approval_required_capability_and_enqueues_durable_child
    runtime = ChildRuntime.new
    profile = ProfileStub.new(
      profile_id: 'trusted',
      tools_allowed: ['read_file'],
      canonical_digest: "sha256:#{'a' * 64}"
    )
    toolbox = Tamoz::Tools::Toolbox.new(root: Dir.tmpdir, allowed_tools: ['read_file'])
    binding = Tamoz::Agent::CapabilityBinding.build(
      toolbox:, child_task_runtime: runtime, profile:
    )

    assert_includes binding.names(:action), 'delegate_child_task'
    refute_includes binding.names(:discovery), 'delegate_child_task'
    assert binding.approval_required?('delegate_child_task')
    assert_equal :idempotent, binding.safety(
      'delegate_child_task', { 'task' => 'inspect note', 'capabilities' => ['local:read_file'] }
    )

    context = Tamoz::Context.new(
      run_id: 'run', execution_id: 'execution', request_id: 'request', thread_id: 'parent'
    )
    result = binding.execute(
      context,
      'delegate_child_task',
      { 'task' => 'inspect note', 'capabilities' => ['local:read_file'] }
    )

    assert_match(/Enqueued durable child child:sha256:/, result)
    child, parent = runtime.child

    assert_equal 'parent', child.parent_thread_id
    assert_equal 'request', child.parent_request_id
    assert_equal ['local:read_file'], child.capability_profile.fetch('capabilities')
    assert_equal profile.canonical_digest, child.capability_profile.fetch('authority_revision')
    assert_equal profile.canonical_digest, parent.fetch('authority_revision')
  end

  def test_candidate_promotion_records_a_next_boundary_transition_without_activation
    Dir.mktmpdir('phase4-candidate') do |directory|
      registry = Tamoz::Agent::Profile::TransitionRegistry.new(
        path: File.join(directory, 'transitions.yml')
      )
      proposal = Tamoz::Agent::Improvement::CandidateProposal.build(
        thread_id: 'thread-1', profile_id: 'trusted',
        from_digest: "sha256:#{'a' * 64}", to_digest: "sha256:#{'b' * 64}",
        scope: 'profile', created_by: 'agent'
      )

      result = proposal.promote!(
        registry:,
        candidate_resolver: lambda { |digest|
          { 'profile_id' => 'trusted', 'digest' => digest, 'scope' => 'profile' }
        },
        actor: 'operator',
        human_gate_evidence: 'human:operator'
      )

      refute result.fetch('activated')
      assert registry.candidate?('thread-1', profile_id: 'trusted',
                                             from: proposal.from_digest, to: proposal.to_digest)
    end
  end

  def test_child_policy_narrows_capabilities_and_stops_at_exhausted_budget
    runtime = ChildRuntime.new
    profile = ProfileStub.new(
      profile_id: 'trusted',
      tools_allowed: %w[read_file list_directory],
      canonical_digest: "sha256:#{'a' * 64}"
    )
    toolbox = Tamoz::Tools::Toolbox.new(root: Dir.tmpdir, allowed_tools: %w[read_file list_directory])
    context = Tamoz::Context.new(
      run_id: 'run', execution_id: 'execution', request_id: 'request', thread_id: 'parent'
    )

    runtime.child_delegation_context = {
      current_depth: 1, remaining_depth: 1, remaining_concurrency: 1,
      capabilities: ['local:read_file']
    }
    binding = Tamoz::Agent::CapabilityBinding.build(toolbox:, child_task_runtime: runtime, profile:)

    assert_raises(Tamoz::Agent::ToolPolicyError) do
      binding.execute(context, 'delegate_child_task',
                      { 'task' => 'widen', 'capabilities' => ['local:list_directory'] })
    end
    binding.execute(context, 'delegate_child_task',
                    { 'task' => 'stay narrow', 'capabilities' => ['local:read_file'] })
    child, = runtime.child

    assert_equal 2, child.depth
    assert_equal 0, child.delegation_policy.fetch('remaining_depth')
    assert_equal 0, child.delegation_policy.fetch('remaining_concurrency')

    runtime.child_delegation_context = {
      current_depth: 2, remaining_depth: 0, remaining_concurrency: 0,
      capabilities: ['local:read_file']
    }
    exhausted = Tamoz::Agent::CapabilityBinding.build(toolbox:, child_task_runtime: runtime, profile:)
    assert_raises(Tamoz::Agent::ToolPolicyError) do
      exhausted.execute(context, 'delegate_child_task',
                        { 'task' => 'recurse', 'capabilities' => ['local:read_file'] })
    end
  end

  def test_browser_source_fails_closed_without_external_adapter_and_rejects_unallowlisted_url
    descriptor = Struct.new(:id, :effect_class).new('mcp:browser/navigate', :read_only)
    source = Tamoz::Agent::GovernedBrowserSource.new(
      adapter: nil, descriptors: [descriptor], allowed_hosts: ['example.com']
    )

    error = assert_raises(Tamoz::Tools::ToolError) do
      source.execute(nil, descriptor.id, { 'url' => 'https://example.com' })
    end
    assert_match(/browser adapter unavailable/, error.message)
    assert_raises(Tamoz::Agent::ToolPolicyError) do
      source.validate(descriptor.id, { 'url' => 'https://not-example.com' })
    end
  end

  def test_browser_source_passes_only_bounded_untrusted_output_to_an_injected_adapter
    descriptor = Struct.new(:id, :effect_class).new('mcp:browser/snapshot', :read_only)
    adapter = Class.new do
      attr_reader :arguments

      def execute(context:, capability_id:, arguments:)
        @arguments = [context, capability_id, arguments]
        { 'output' => 'x' * (Tamoz::Agent::GovernedBrowserSource::MAX_OUTPUT_BYTES + 1) }
      end
    end.new
    source = Tamoz::Agent::GovernedBrowserSource.new(
      adapter:, descriptors: [descriptor], allowed_hosts: ['example.com']
    )

    outcome = source.execute(:context, descriptor.id, { 'url' => 'https://example.com' })

    assert_equal :succeeded, outcome.status
    assert_equal Tamoz::Agent::GovernedBrowserSource::MAX_OUTPUT_BYTES,
                 outcome.observation.text.bytesize
    assert outcome.observation.truncated
    assert_equal descriptor.id, adapter.arguments.fetch(1)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
end
