# frozen_string_literal: true

require_relative 'sqlite_harness_scenarios'

module SQLiteHarnessStates
  OPERATION_PROBES = {
    'lease.acquire' => 'lease-fencing',
    'lease.validate' => 'lease-fencing',
    'lease.renew' => 'lease-fencing',
    'lease.release' => 'lease-fencing',
    'request.enqueue' => 'inbox-reopen',
    'request.claim' => 'inbox-reopen',
    'request.transition' => 'inbox-reopen',
    'request.recover' => 'request-recovery',
    'request.redirect_ready' => 'checkpoint-reopen',
    'checkpoint.append_writes' => 'pending-write-replay',
    'checkpoint.commit' => 'checkpoint-reopen'
  }.freeze
  VARIANT_PROBES = {
    'request.recover' => [/stale\z/, 'stale-request-fail'],
    'checkpoint.commit' => [/turn|failed/, 'request-checkpoint-reopen']
  }.freeze
  PROBE_BY_ID = {
    'request.enqueue-duplicate' => 'duplicate-delivery',
    'request.claim-stale' => 'stale-request-fail'
  }.freeze

  module_function

  def probes
    @probes ||= SQLiteHarnessScenarios.scenarios.to_h { |entry| [entry.fetch('id'), probe_for(entry)] }.freeze
  end

  def probe_for(entry)
    id = entry.fetch('id')
    return PROBE_BY_ID.fetch(id) if PROBE_BY_ID.key?(id)

    operation = entry.fetch('operation')
    pattern, variant = VARIANT_PROBES.fetch(operation, [nil, nil])
    pattern && id.match?(pattern) ? variant : OPERATION_PROBES.fetch(operation)
  end

  def request_states
    {
      'request.enqueue-new' => { 'old' => nil, 'new' => 'queued' },
      'request.claim-turn' => { 'old' => 'queued', 'new' => 'claimed' },
      'request.claim-resume' => { 'old' => 'queued', 'new' => 'claimed' },
      'request.claim-redirect' => { 'old' => 'queued', 'new' => 'redirecting' },
      'request.claim-stale' => { 'old' => 'queued', 'new' => 'failed' },
      'request.mark-running' => { 'old' => 'claimed', 'new' => 'running' },
      'request.mark-redirect-running' => { 'old' => 'redirecting', 'new' => 'running' },
      'request.recover-stale' => { 'old' => 'claimed', 'new' => 'failed' }
    }
  end

  def checkpoint_states
    {
      'request.redirect-ready' => { 'stable' => [1, 'running'] },
      'checkpoint.commit-start' => { 'old' => [0, nil], 'new' => [1, 'running'] },
      'checkpoint.commit-advance' => { 'old' => [1, 'running'], 'new' => [2, 'completed'] },
      'checkpoint.commit-fork' => { 'old' => [2, 'completed'], 'new' => [3, 'completed'] },
      'checkpoint.commit-paused' => { 'old' => [1, 'running'], 'new' => [2, 'paused'] }
    }
  end

  def request_checkpoint_states
    {
      'checkpoint.commit-turn' => { 'old' => [1, 'running', 'claimed'], 'new' => [2, 'completed', 'completed'] },
      'checkpoint.commit-failed' => { 'old' => [1, 'running', 'claimed'], 'new' => [2, 'failed', 'failed'] }
    }
  end

  def recovery_history_counts
    {
      'request.recover-claimed' => 2,
      'request.recover-running' => 2,
      'request.recover-redirecting' => 3
    }
  end

  def preparers
    @preparers ||= SQLiteHarnessScenarios.scenarios.to_h do |entry|
      [entry.fetch('id'), "prepare_#{entry.fetch('id').tr('.', '_').tr('-', '_')}"]
    end
  end
end
