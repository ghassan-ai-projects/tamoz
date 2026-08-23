# frozen_string_literal: true

require 'tamoz/core'

module Tamoz
  module Approval
    # Single policy owner: construct requests, evaluate policy, mint grants,
    # resolve answers, and reload policy without breaking in-flight sessions.
    #
    # Time contract: `clock` is a callable returning wall-clock Time; every
    # persisted millisecond value (`created_at_ms`, `expires_at_ms`) is epoch
    # milliseconds derived from it, so durable rows survive process restarts.
    # Expiry filtering lives here, not in the grant stores, so there is one
    # time basis for the whole feature.
    class Engine
      attr_reader :policy, :grant_store, :decision_log

      def initialize(policy:, grant_store:, decision_log:, clock:, evidence_symbols:, workspace_root: nil)
        @policy = policy
        @grant_store = grant_store
        @decision_log = decision_log
        @clock = clock
        @evidence_symbols = evidence_symbols
        @workspace_root = workspace_root || Dir.pwd
        @documents = { policy.policy_rev => policy }
        @session_revs = {}
        @mutex = Mutex.new
      end

      def build_request(tool:, argv:, targets:, effect_class:, session_id:, workspace_root: nil)
        policy = policy_for(session_id)
        Request.new(
          tool: tool.to_sym,
          verb: policy.verb_for(tool.to_sym, effect_class),
          argv: Array(argv).map(&:to_s),
          targets: Array(targets).map { |target| canonicalize_target(target, workspace_root || @workspace_root) },
          effect_class: effect_class.to_sym,
          session_id: session_id.to_s
        )
      end

      def decide(request)
        policy = policy_for(request.session_id)
        decision = Evaluator.new(policy).evaluate(request)

        if decision.verdict == :ask
          grant = find_live_session_grant(decision, request.session_id, policy.policy_rev)
          return log_grant_hit(decision, request) if grant
        end

        log_decision(decision, request)
        decision
      end

      def resolve(decision_id:, answer:, scope:, actor_evidence: nil, expires_at_ms: nil)
        validate_answer(answer)
        raise InvalidScopeError, 'deny takes no scope' if answer == :deny && !scope.nil?
        validate_actor_evidence(actor_evidence)

        # One critical section for lookup→record→insert: two concurrent
        # replays of the same answer must produce exactly one grant row, so
        # the loser must observe the winner's resolution, not race it.
        @mutex.synchronize do
          decision_record = decision_log.lookup(decision_id)
          raise UnknownDecisionError, "no decision #{decision_id}" unless decision_record

          recorded = decision_log.lookup_resolution(decision_id)
          return recorded.fetch(:grant) if replay?(recorded, answer, scope)
          raise ConflictingResolutionError, conflicting_message(decision_id, recorded) if recorded

          # Record first, insert second — and insert exactly what the log
          # recorded, never a freshly minted duplicate.
          grant = mint_grant(decision_record.fetch(:decision), answer, scope, expires_at_ms)
          recorded_resolution = decision_log.record_resolution(
            decision_id: decision_id,
            answer: answer,
            scope: scope,
            actor_evidence: actor_evidence,
            grant: grant
          )
          stored_grant = recorded_resolution.fetch(:grant)
          grant_store.insert(stored_grant) if stored_grant
          stored_grant
        end
      end

      def simulate(request)
        Evaluator.new(policy_for(request.session_id)).evaluate(request)
      end

      def reload(source)
        new_policy = load_policy(source)
        @mutex.synchronize do
          # The documents entry lands before the pointer flips so bound
          # sessions never observe a gap.
          @documents[new_policy.policy_rev] = new_policy
          @policy = new_policy
        end
        new_policy.policy_rev
      end

      def bind_session(session_id)
        @mutex.synchronize do
          rev = @policy.policy_rev
          @session_revs[session_id.to_s] = rev
          rev
        end
      end

      def release_session(session_id)
        @mutex.synchronize do
          id = session_id.to_s
          rev = @session_revs.delete(id)
          next unless rev
          next if rev == @policy.policy_rev
          next if @session_revs.value?(rev)

          @documents.delete(rev)
        end
        nil
      end

      # Session teardown is one verb on the engine: unpin the rev and purge
      # the session's grants together.
      def close_session(session_id)
        release_session(session_id)
        grant_store.delete_by_session(session_id)
        nil
      end

      private

      def validate_answer(answer)
        return if Answer::VERDICTS.include?(answer)

        raise ArgumentError, "answer must be :approve or :deny, got #{answer.inspect}"
      end

      # Actor evidence is validated here against the injected symbol set but
      # deliberately NOT compared against the decision's required_evidence:
      # enforcement of the requirement lives in comms' binding check, which
      # sees the actual channel identity. Re-checking it from a caller-passed
      # value would let the caller assert its own authority.
      def validate_actor_evidence(actor_evidence)
        return unless actor_evidence
        return if @evidence_symbols.include?(actor_evidence.to_sym)

        raise ArgumentError, "unknown actor evidence #{actor_evidence.inspect}"
      end

      def mint_grant(decision, answer, scope, expires_at_ms)
        return nil unless answer == :approve

        raise InvalidScopeError, "decision #{decision.id} has no grant offer" unless decision.grant_offer
        raise InvalidScopeError, "scope #{scope.inspect} not offered" unless decision.grant_offer.scopes.include?(scope)

        Grant.new(
          key: decision.grant_offer.key,
          scope: scope,
          session_id: decision.session_id,
          policy_rev: decision.policy_rev,
          created_at_ms: now_ms,
          expires_at_ms: expires_at_ms
        )
      end

      def load_policy(source)
        case source
        when PolicyDocument then source
        when String then PolicyDocument.load(source, evidence_symbols: @evidence_symbols)
        else raise ArgumentError, "reload expects a PolicyDocument or path string"
        end
      end

      def policy_for(session_id)
        @mutex.synchronize do
          rev = @session_revs[session_id.to_s]
          rev ? @documents.fetch(rev) : @policy
        end
      end

      def find_live_session_grant(decision, session_id, policy_rev)
        return nil unless decision.grant_offer
        return nil unless decision.grant_offer.scopes.include?(:session)
        return nil unless decision.grant_offer.key

        grant = grant_store.lookup(
          key: decision.grant_offer.key,
          scope: :session,
          session_id: session_id,
          policy_rev: policy_rev
        )
        return nil unless grant
        return nil if grant.expires_at_ms && grant.expires_at_ms <= now_ms

        grant
      end

      # A grant-hit allow shares the request digest with its original ask;
      # reusing the bare decision id would collide with the logged :ask
      # record, so the auto-allow logs under a derived id instead.
      def log_grant_hit(decision, request)
        hit = decision.with(
          id: "#{decision.id}/grant",
          verdict: :allow,
          reason: 'session grant',
          rule_id: 'engine.grant_hit',
          grant_offer: nil,
          required_evidence: nil
        )
        log_decision(hit, request)
        hit
      end

      def log_decision(decision, request)
        decision_log.append(
          decision_id: decision.id,
          tool: request.tool.to_s,
          verb: request.verb.to_s,
          tier: decision.tier.to_s,
          rule_id: decision.rule_id.to_s,
          verdict: decision.verdict.to_s,
          evidence: decision.required_evidence&.to_s,
          policy_rev: decision.policy_rev,
          argv_digest: Canonical.hexdigest(request.argv),
          targets_digest: Canonical.hexdigest(request.targets),
          session_id: request.session_id,
          decision: decision
        )
      end

      def replay?(recorded, answer, scope)
        recorded && recorded[:answer] == answer && recorded[:scope] == scope
      end

      def conflicting_message(decision_id, recorded)
        "decision #{decision_id} already resolved as #{recorded[:answer]}/#{recorded[:scope]}"
      end

      def canonicalize_target(target, workspace_root)
        target = target.to_s
        return target if target.include?('://')

        # A symlink whose target is gone resolves nowhere: canonicalize the
        # literal path so glob denies still match it, rather than crashing.
        if File.symlink?(target) && !File.exist?(target)
          return File.expand_path(target, workspace_root)
        end

        return File.realpath(target, workspace_root) if File.exist?(target)

        File.expand_path(target, workspace_root)
      end

      def now_ms
        (@clock.call.to_f * 1000).to_i
      end
    end
  end
end
