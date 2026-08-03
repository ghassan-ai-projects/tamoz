# frozen_string_literal: true

require_relative "test_helper"

# Shared builders for the P12-HD/H1/H2 suites. Deliberately NOT a `_test.rb` file
# so the Rake pattern does not load it standalone.
module HealingFixtures
  Healing = Tamoz::Agent::Healing

  ORACLE_ARGV = ["/bin/sh", "-c", "grep -q healed answer.txt"].freeze

  # A workspace whose configured check `answer` passes only once the fault is
  # repaired. The check is a child process with a credential-free environment —
  # the existing `run_check` machinery, not a second runner.
  def with_healing_workspace(content: "broken\n")
    Dir.mktmpdir("tamoz-healing") do |dir|
      File.write(File.join(dir, "answer.txt"), content, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(
        root: dir, allow_changes: true, checks: {"answer" => ORACLE_ARGV}
      )
      yield dir, toolbox
    end
  end

  def failure_record(**overrides)
    defaults = {
      failure_code: "workspace.stale_precondition",
      category: :stale_precondition,
      operation: "tool.apply_patch",
      tool: "apply_patch",
      target_resource: "answer.txt",
      expected_digest: "sha256:#{"a" * 64}",
      observed_digest: "sha256:#{"b" * 64}",
      effect_state: :not_attempted,
      graph_id: "graph.agent-session",
      task_id: "task.1",
      execution_id: "execution.1",
      policy_version: "policy/1",
      behavior_version: "tamoz.agent.session/1",
      retryability: {"pre_dispatch" => false, "effect_safety" => "reconcilable"},
      trusted_context: {"original_operation_authorized" => true},
      observed_at_ms: 1_700_000_000_000
    }
    Healing::FailureRecord.new(**defaults.merge(overrides))
  end

  def healing_rule(toolbox: nil, oracle_digest: nil, **overrides)
    digest = oracle_digest || Healing::Oracle.digest_for(toolbox, "answer")
    defaults = {
      rule_id: "rule.stale-conditional-file-edit",
      version: 1,
      owner: "human:owner",
      lifecycle_mode: :shadow,
      trigger: {"categories" => ["stale_precondition"]},
      minimum_confidence: 1.0,
      risk_class: :low,
      effect_class: :reconcilable,
      authorized_scopes: ["workspace"],
      authorized_resources: ["answer.txt"],
      plan_review_policy: {
        "plan_required" => true,
        "semantic_critic_required" => true,
        "human_approval_required" => true
      },
      preconditions: Healing::Preflight::CHECK_IDS.map(&:to_s),
      remediation_steps: [
        {"form" => "refresh_recompute", "safety" => "reconcilable", "creates" => false}
      ],
      effect_identity: {"domain" => Healing::EffectIdentity::DOMAIN},
      budgets: {
        "max_attempts" => 2, "max_magnitude" => 1.0,
        "max_cost" => 1.0, "max_seconds" => 30.0
      },
      verification_oracle: {
        "kind" => "configured_check", "check_name" => "answer", "digest" => digest
      },
      compensation: {"kind" => "restore_preimage"},
      circuit_conditions: %w[verification_failed_twice compensation_failed],
      reset_authority: "human:owner",
      escalation_contract: {
        "sink" => "tamoz.escalations",
        "recommended_next_action" => "re-read the target and recompute one minimal patch"
      },
      eval_suite: "tamoz.evals.healing.stale-edit",
      created_at_ms: 1_700_000_000_000
    }
    Healing::HealingRule.new(**defaults.merge(overrides))
  end

  # The semantic critic seam. A deterministic stand-in — the protocol only ever
  # receives an INJECTED callable, which is why nothing in `Healing` loads a
  # model client (the dependency-isolation test stays green).
  def accepting_critic
    ->(_plan) { {"decision" => "accept", "issues" => [], "rationale" => "equivalent to intent"} }
  end

  # A rule that triggers on effect_unknown (family :reconcile): the reconcile
  # path never performs — the reconciler runs, then the attempt escalates.
  def reconcile_rule(toolbox: nil, oracle_digest: nil, **overrides)
    digest = oracle_digest || Healing::Oracle.digest_for(toolbox, "answer")
    defaults = {
      rule_id: "rule.reconcile-unknown-effect",
      version: 1,
      owner: "human:owner",
      lifecycle_mode: :shadow,
      trigger: {"categories" => %w[effect_unknown]},
      minimum_confidence: 1.0,
      risk_class: :low,
      effect_class: :reconcilable,
      authorized_scopes: ["workspace"],
      authorized_resources: ["answer.txt"],
      plan_review_policy: {
        "plan_required" => true,
        "semantic_critic_required" => true,
        "human_approval_required" => true
      },
      preconditions: Healing::Preflight::CHECK_IDS.map(&:to_s),
      remediation_steps: [
        {"form" => "refresh_recompute", "safety" => "reconcilable", "creates" => false}
      ],
      effect_identity: {"domain" => Healing::EffectIdentity::DOMAIN},
      budgets: {
        "max_attempts" => 2, "max_magnitude" => 1.0,
        "max_cost" => 1.0, "max_seconds" => 30.0
      },
      verification_oracle: {
        "kind" => "configured_check", "check_name" => "answer", "digest" => digest
      },
      compensation: {"kind" => "restore_preimage"},
      circuit_conditions: %w[verification_failed_twice compensation_failed],
      reset_authority: "human:owner",
      escalation_contract: {
        "sink" => "tamoz.escalations",
        "recommended_next_action" => "reconcile the unknown effect before any retry"
      },
      eval_suite: "tamoz.evals.healing.reconcile",
      created_at_ms: 1_700_000_000_000
    }
    Healing::HealingRule.new(**defaults.merge(overrides))
  end

  def rejecting_critic(issue: "the remediation is broader than the original intent")
    ->(_plan) { {"decision" => "revise", "issues" => [issue], "rationale" => "not equivalent"} }
  end

  # A real durable graph + effect journal, so the remediation runs through the
  # EXISTING effect machinery rather than a test double.
  def with_effect_context(thread: "thread.healing", task_id: "task.healing")
    Dir.mktmpdir("tamoz-healing-db") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 5.0)
      )
      begin
        definition = Tamoz.graph(name: "healing-base", version: "1") do
          state :ready, default: false
          node(:finish, implementation_name: "healing.finish", version: "1") do |_state, _context|
            {ready: true}
          end
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        app = definition.compile(checkpointer: adapter)
        request = app.durable_runner.deliver({}, thread:, request_id: "request.healing")
        app.checkpointer.open_writer(
          thread_id: thread, namespace: [], owner_id: "healing.owner",
          ttl: app.checkpointer.writer_ttl
        ) do |writer|
          yield Tamoz::Context.new(
            run_id: "run.healing", execution_id: request.execution_id,
            request_id: "request.healing", task_id:, effects: writer.effects
          )
        end
      ensure
        adapter&.close
      end
    end
  end

  # Every one of the twelve design §3 categories, as a typed record. Used by the
  # classification matrix so no category can quietly go untested.
  def synthetic_records
    {
      transient_pre_dispatch: failure_record(
        failure_code: "provider.connect_reset", category: :transient_pre_dispatch,
        operation: "model.call", tool: nil, target_resource: nil,
        expected_digest: nil, observed_digest: nil,
        retryability: {"pre_dispatch" => true, "effect_safety" => "read_only"}
      ),
      stale_precondition: failure_record,
      dependency_unavailable: failure_record(
        failure_code: "mcp.server_unavailable", category: :dependency_unavailable,
        operation: "tool.mcp:server/call", tool: "mcp:server/call",
        target_resource: "mcp:server", expected_digest: nil, observed_digest: nil
      ),
      malformed_recoverable_output: failure_record(
        failure_code: "tool.malformed_output", category: :malformed_recoverable_output,
        operation: "tool.read_file", tool: "read_file",
        expected_digest: nil, observed_digest: nil
      ),
      resource_exhausted: failure_record(
        failure_code: "budget.exhausted", category: :resource_exhausted,
        operation: "session.turn", tool: nil, target_resource: nil,
        expected_digest: nil, observed_digest: nil
      ),
      policy_denied: failure_record(
        failure_code: "policy.root_escape", category: :policy_denied,
        operation: "tool.read_file", tool: "read_file", target_resource: "/etc/passwd",
        expected_digest: nil, observed_digest: nil
      ),
      effect_unknown: failure_record(
        failure_code: "effect.timeout_after_dispatch", category: :effect_unknown,
        operation: "tool.apply_patch", tool: "apply_patch", effect_state: :unknown,
        expected_digest: nil, observed_digest: nil
      ),
      verification_failed: failure_record(
        failure_code: "check.failed", category: :verification_failed,
        operation: "tool.run_check", tool: "run_check", target_resource: "answer",
        expected_digest: nil, observed_digest: nil
      ),
      derived_state_corrupt: failure_record(
        failure_code: "index.corrupt", category: :derived_state_corrupt,
        operation: "memory.lexical_index", tool: nil, target_resource: "memory.index",
        expected_digest: nil, observed_digest: nil
      ),
      durable_state_corrupt: failure_record(
        failure_code: "checkpoint.corrupt", category: :durable_state_corrupt,
        operation: "checkpoint.load", tool: nil, target_resource: "thread.1",
        expected_digest: nil, observed_digest: nil
      ),
      programmer_error: failure_record(
        failure_code: "runtime.no_method_error", category: :programmer_error,
        operation: "session.node", tool: nil, target_resource: nil,
        expected_digest: nil, observed_digest: nil
      ),
      unknown: failure_record(
        failure_code: "unclassified", category: :unknown,
        operation: "session.turn", tool: nil, target_resource: nil,
        expected_digest: nil, observed_digest: nil
      )
    }
  end
end
