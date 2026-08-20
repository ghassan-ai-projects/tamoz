# frozen_string_literal: true

module Tamoz
  module Stream
    # Base error for the stream package. Typed failures (invariant 17):
    # admission rejections/quarantines are DURABLE OUTCOMES, never raised; the
    # raised classes are the operational failures below.
    class StreamError < Tamoz::Error
      CATEGORY = "stream"
      RETRYABLE = false
      SAFE_MESSAGE = "A stream operation failed."
    end

    # T1.5: a received situation snapshot failed its digest verification
    # (tampered or drifted). The episode terminates before any model call.
    class SnapshotDigestMismatchError < StreamError
      CATEGORY = "stream_snapshot_digest_mismatch"
      SAFE_MESSAGE = "The situation snapshot failed digest verification."
    end

    # T1.5: a received situation snapshot lacks the identity fields the worker
    # needs to scope the episode (situation_id, situation_version, tenant,
    # entity identity).
    class SnapshotIdentityError < StreamError
      CATEGORY = "stream_snapshot_identity"
      SAFE_MESSAGE = "The situation snapshot is missing identity fields."
    end

    # T1.2: the runtime's handshake or request does not match the worker's
    # contract major (protocol/contract version, non-interactive mode).
    class ContractMismatchError < StreamError
      CATEGORY = "stream_contract_mismatch"
      SAFE_MESSAGE = "The stream contract version does not match."
    end

    # T1.3': an EpisodeRequest failed validation (identity, kind, lane, risk
    # ceiling). The episode terminates before any model call.
    class EpisodeRequestInvalidError < StreamError
      CATEGORY = "stream_episode_request_invalid"
      SAFE_MESSAGE = "The episode request is invalid."
    end

    # T2.2: a budget ceiling was crossed mid-run; the episode aborts typed.
    class BudgetExceededError < StreamError
      CATEGORY = "stream_budget_exceeded"
      SAFE_MESSAGE = "The episode budget was exceeded."
    end
  end
end
