# frozen_string_literal: true

require_relative 'sqlite_harness_coverage'

module SQLiteHarnessScenarios
  include SQLiteHarnessCoverage

  OLD_NEW = %w[old new].freeze
  STABLE = %w[stable].freeze

  SPECS = [
    ['lease.acquire-new', 'lease', 'lease.acquire', LEASE_ACQUIRE],
    ['lease.acquire-takeover', 'lease', 'lease.acquire', LEASE_ACQUIRE],
    ['lease.validate', 'lease', 'lease.validate', LEASE_VALIDATE],
    ['lease.renew', 'lease', 'lease.renew', LEASE_RENEW],
    ['lease.release', 'lease', 'lease.release', LEASE_RELEASE],
    ['request.enqueue-new', 'request', 'request.enqueue', ENQUEUE_NEW],
    ['request.enqueue-duplicate', 'request', 'request.enqueue', ENQUEUE_DUPLICATE, STABLE],
    ['request.claim-turn', 'request', 'request.claim', CLAIM_TURN],
    ['request.claim-resume', 'request', 'request.claim', CLAIM_RESUME],
    ['request.claim-redirect', 'request', 'request.claim', CLAIM_REDIRECT],
    ['request.claim-stale', 'request', 'request.claim', CLAIM_STALE],
    ['request.recover-claimed', 'request', 'request.recover', RECOVER],
    ['request.recover-running', 'request', 'request.recover', RECOVER],
    ['request.recover-redirecting', 'request', 'request.recover', RECOVER],
    ['request.recover-stale', 'request', 'request.recover', RECOVER_STALE],
    ['request.mark-running', 'request', 'request.transition', TRANSITION],
    ['request.mark-redirect-running', 'request', 'request.transition', TRANSITION],
    ['request.redirect-ready', 'request', 'request.redirect_ready', REDIRECT_READY, STABLE],
    ['checkpoint.writes-new', 'checkpoint', 'checkpoint.append_writes', WRITES_NEW],
    ['checkpoint.writes-duplicate', 'checkpoint', 'checkpoint.append_writes', WRITES_DUPLICATE, STABLE],
    ['checkpoint.commit-start', 'checkpoint', 'checkpoint.commit', COMMIT_START],
    ['checkpoint.commit-advance', 'checkpoint', 'checkpoint.commit', COMMIT_ADVANCE],
    ['checkpoint.commit-turn', 'checkpoint', 'checkpoint.commit', COMMIT_TURN],
    ['checkpoint.commit-fork', 'checkpoint', 'checkpoint.commit', COMMIT_PLAIN],
    ['checkpoint.commit-paused', 'checkpoint', 'checkpoint.commit', COMMIT_PLAIN],
    ['checkpoint.commit-failed', 'checkpoint', 'checkpoint.commit', COMMIT_TURN]
  ].freeze

  module_function

  def scenario(id, family:, operation:, coverage:, state_classes: OLD_NEW)
    {
      'id' => id,
      'version' => 1,
      'family' => family,
      'operation' => operation,
      'setup' => id,
      'action' => operation,
      'state_classes' => state_classes,
      'contract' => id,
      'convergence' => id,
      'coverage' => coverage
    }
  end

  def scenarios
    @scenarios ||= Tamoz::Evals::DeepFreeze.call(
      SPECS.map do |id, family, operation, coverage, state_classes = OLD_NEW|
        scenario(id, family:, operation:, coverage:, state_classes:)
      end
    )
  end
end
