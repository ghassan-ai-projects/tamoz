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
        @switch_sequence = 0
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

      def decide(request, step_scope: '')
        policy = policy_for(request.session_id)
        decision = Evaluator.new(policy).evaluate(request)

        if decision.verdict == :ask
          grant = find_live_session_grant(decision, request.session_id, policy.policy_rev)
          return log_grant_hit(decision, request) if grant
        end

        log_decision(decision, request, step_scope:)
        decision
      end

      # A durable gate replays: after a crash or pause the same gate evaluates
      # again. The ISSUING decision owns the step — the replay reuses it even
      # after the operator answered it or the policy moved meanwhile, so an
      # in-flight step is never re-decided (MS-4). A different question carries
      # a different step scope or argv and never collides.
      def decide_or_reuse(request, step_scope:)
        existing = decision_log.latest_decision_for(
          session_id: request.session_id,
          argv_digest: Canonical.hexdigest(request.argv),
          targets_digest: Canonical.hexdigest(request.targets),
          step_scope:
        )
        return existing if existing

        decide(request, step_scope:)
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
        id = session_id.to_s
        @mutex.synchronize do
          # A durable switch outranks the boot rev: engines are rebuilt per
          # process, and the operator's mid-session mode must survive that.
          rev = durable_override(id) || @policy.policy_rev
          @session_revs[id] = rev
          rev
        end
      end

      # The §2.6 exception to in-flight rev stability: an explicit,
      # operator-addressed rebind of ONE session's (profile, policy_rev). It
      # governs the next decide only — nothing retroactive; tightening drops
      # the session's old-rev grants for free, because grant lookup keys on the
      # bound rev. A caller-supplied switch_id makes a replayed application
      # append at most one audit record.
      def rebind_session(profile:, session_id:, actor_id: 'operator', switch_id: nil)
        new_policy = PolicyDocument.load_profile(@policy.path, profile.to_s, evidence_symbols: @evidence_symbols)
        prior = nil
        @mutex.synchronize do
          prior = @session_revs[session_id.to_s]
          next if prior == new_policy.policy_rev

          # The documents entry lands before the pointer flips so the next
          # decide never observes a gap (same invariant as reload).
          @documents[new_policy.policy_rev] = new_policy
          @session_revs[session_id.to_s] = new_policy.policy_rev
        end
        return new_policy.policy_rev if prior == new_policy.policy_rev

        record_switch(
          switch_id || next_switch_id(session_id, prior, new_policy.policy_rev),
          session_id: session_id.to_s,
          actor_id: actor_id,
          from_rev: prior,
          to_rev: new_policy.policy_rev,
          profile_name: profile.to_s
        )
        new_policy.policy_rev
      end

      def bound?(session_id)
        @mutex.synchronize { @session_revs.key?(session_id.to_s) }
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

      def record_switch(id, session_id:, actor_id:, from_rev:, to_rev:, profile_name:)
        decision_log.record_mode_switch(
          id: id,
          session_id: session_id,
          actor_id: actor_id,
          from_rev: from_rev,
          to_rev: to_rev,
          profile_name:,
          ts_ms: now_ms
        )
      rescue ConflictingResolutionError
        # A replayed switch whose from-rev drifted (the global pointer moved
        # between crash and retry) still applied exactly once as long as the
        # recorded destination is this one.
        recorded = decision_log.lookup_mode_switch(id)
        raise if recorded.nil? || recorded.fetch(:to_rev) != to_rev
      end

      def next_switch_id(session_id, from_rev, to_rev)
        sequence = @mutex.synchronize { @switch_sequence += 1 }
        Canonical.hexdigest(['tamoz.approval.mode_switch', session_id, from_rev, to_rev, sequence])
      end

      # The newest recorded switch for a session, loaded through the decision
      # log so a rebind outlives the engine instance that applied it. The
      # document is registered so lookups never observe a gap.
      def durable_override(session_id)
        latest = decision_log.latest_mode_switch(session_id)
        return nil unless latest

        rev = latest.fetch(:to_rev)
        unless @documents.key?(rev)
          rebuilt = PolicyDocument.load_profile(
            @policy.path, latest.fetch(:profile_name), evidence_symbols: @evidence_symbols
          )
          @documents[rev] = rebuilt if rebuilt.policy_rev == rev
        end
        raise UnknownDecisionError, "cannot reconstruct policy #{rev}" unless @documents.key?(rev)

        rev
      end

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
        id = session_id.to_s
        @mutex.synchronize do
          rev = @session_revs[id]
          unless rev
            rev = durable_override(id)
            @session_revs[id] = rev if rev
          end
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

      def log_decision(decision, request, step_scope: '')
        decision_log.append(
          decision_id: decision.id,
          step_scope: step_scope,
          tool: request.tool.to_s,
          verb: request.verb.to_s,
          tier: decision.tier.to_s,
          rule_id: decision.rule_id.to_s,
          verdict: decision.verdict.to_s,
          reason: decision.reason,
          evidence: decision.required_evidence&.to_s,
          policy_rev: decision.policy_rev,
          argv_digest: Canonical.hexdigest(request.argv),
          targets_digest: Canonical.hexdigest(request.targets),
          session_id: request.session_id,
          grant_scopes: decision.grant_offer&.scopes,
          grant_key: decision.grant_offer&.key,
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
