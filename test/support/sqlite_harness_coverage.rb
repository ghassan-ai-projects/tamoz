# frozen_string_literal: true

module SQLiteHarnessCoverage
  LEASE_ACQUIRE = %w[
    lease.acquire.time lease.acquire.thread lease.acquire.thread_state
    lease.acquire.namespace lease.acquire.row lease.acquire.update
  ].freeze
  LEASE_VALIDATE = %w[
    lease.validate.time lease.validate.thread lease.validate.row
    lease.validate.clock
  ].freeze
  LEASE_RENEW = %w[
    lease.renew.time lease.renew.thread lease.renew.row lease.renew.update
  ].freeze
  LEASE_RELEASE = %w[
    lease.release.time lease.release.row lease.release.update
  ].freeze
  ENQUEUE_NEW = %w[
    request.enqueue.time request.enqueue.thread request.enqueue.tombstone
    request.enqueue.namespace request.enqueue.existing request.enqueue.sequence
    request.enqueue.insert request.transition.index request.transition.insert
    request.enqueue.advance request.enqueue.result
  ].freeze
  ENQUEUE_DUPLICATE = %w[
    request.enqueue.time request.enqueue.thread request.enqueue.tombstone
    request.enqueue.namespace request.enqueue.existing
  ].freeze
  CLAIM_BASE = %w[
    request.claim.time request.claim.lease.thread request.claim.lease.row
    request.claim.candidates
  ].freeze
  CLAIM_TAIL = %w[
    request.claim.update request.transition.index request.transition.insert
    request.claim.result
  ].freeze
  CLAIM_TURN = (CLAIM_BASE + CLAIM_TAIL).freeze
  CLAIM_RESUME = (CLAIM_BASE + ['request.claim.active_execution'] + CLAIM_TAIL).freeze
  CLAIM_REDIRECT = (CLAIM_BASE + %w[request.claim.redirect_target request.claim.cancellation_generation] +
                    CLAIM_TAIL).freeze
  CLAIM_STALE = (CLAIM_BASE + %w[request.claim.latest_checkpoint request.terminal_fail request.transition.index
                                 request.transition.insert request.claim.result]).freeze
  RECOVER = %w[
    request.recover.time request.recover.lease.thread request.recover.lease.row
    request.recover.row request.recover.earlier request.recover.update
    request.transition.index request.transition.insert request.recover.result
  ].freeze
  RECOVER_STALE = %w[request.recover.time request.recover.lease.thread
                     request.recover.lease.row request.recover.row
                     request.recover.earlier request.recover.latest_checkpoint
                     request.terminal_fail request.transition.index
                     request.transition.insert request.recover.result].freeze
  TRANSITION = %w[
    request.transition.time request.transition.lease.thread
    request.transition.lease.row request.commit.row request.commit.update
    request.transition.index request.transition.insert request.transition.result
  ].freeze
  REDIRECT_READY = %w[request.redirect_ready.time request.redirect_ready.lease.thread
                      request.redirect_ready.lease.row request.redirect_ready.effects].freeze
  WRITES = %w[
    checkpoint.writes.time checkpoint.writes.lease.thread
    checkpoint.writes.lease.row checkpoint.writes.base checkpoint.writes.existing
  ].freeze
  WRITES_NEW = (WRITES + %w[checkpoint.writes.activation checkpoint.writes.item.{index}]).freeze
  WRITES_DUPLICATE = (WRITES + ['checkpoint.writes.verify']).freeze
  COMMIT = %w[
    checkpoint.commit.time checkpoint.commit.lease.thread
    checkpoint.commit.lease.row checkpoint.commit.head
  ].freeze
  REQUEST_COMMIT = %w[
    request.commit.row request.commit.update request.transition.index
    request.transition.insert
  ].freeze
  COMMIT_START = (COMMIT + %w[checkpoint.commit.insert checkpoint.commit.advance]).freeze
  COMMIT_ADVANCE = (COMMIT + %w[checkpoint.commit.base checkpoint.commit.insert
                                checkpoint.commit.consume.{index} checkpoint.commit.advance]).freeze
  COMMIT_TURN = (COMMIT + %w[checkpoint.commit.base checkpoint.commit.insert] + REQUEST_COMMIT +
                 ['checkpoint.commit.advance']).freeze
  COMMIT_PLAIN = (COMMIT + %w[checkpoint.commit.base checkpoint.commit.insert checkpoint.commit.advance]).freeze
end
