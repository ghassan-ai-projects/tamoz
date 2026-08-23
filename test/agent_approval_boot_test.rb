# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require 'stringio'

# Phase 6 boot wiring: the worker builds the durable engine at boot, the run
# config can point it at operator-owned policy data, and the reload-delivery
# loop moves a validated pointer into running workers.
class AgentApprovalBootTest < Minitest::Test
  include AutonomyCase

  def test_worker_boots_the_durable_engine_from_the_bundled_policy
    with_runtime do |rt|
      open_runtime(rt) do |runtime|
        engine = runtime.approval_engine
        assert_instance_of Tamoz::Approval::Engine, engine
        assert_equal Tamoz::Approval.bundled_policy_path, engine.policy.path
        assert_equal 'implement', engine.policy.profile_name
        assert_instance_of Tamoz::SQLite::ApprovalGrantStore, engine.grant_store
        assert_instance_of Tamoz::SQLite::ApprovalDecisionLog, engine.decision_log
      end
    end
  end

  def test_run_config_overrides_policy_path_and_profile
    with_runtime do |rt|
      Dir.mktmpdir do |policy_dir|
        File.write(File.join(policy_dir, 'base.yaml'), MINIMAL_POLICY)
        FileUtils.mkdir_p(File.join(policy_dir, 'profiles'))
        File.write(File.join(policy_dir, 'profiles', 'review.yaml'), "version: 1\nprofile:\n  name: review\n")

        override_config(rt, 'policy_path' => File.join(policy_dir, 'base.yaml'), 'profile' => 'review')

        open_runtime(rt) do |runtime|
          assert_equal File.join(policy_dir, 'base.yaml'), runtime.approval_engine.policy.path
          assert_equal 'review', runtime.approval_engine.policy.profile_name
        end
      end
    end
  end

  def test_reload_delivery_pickup_and_fail_closed_halves
    with_runtime do |rt|
      Dir.mktmpdir do |policy_dir|
        good_path = File.join(policy_dir, 'good.yaml')
        File.write(good_path, MINIMAL_POLICY.sub('timeout_s: 900', 'timeout_s: 60'))
        good_rev = Tamoz::Approval::PolicyDocument.load(good_path, evidence_symbols: evidence_set).policy_rev
        broken_path = File.join(policy_dir, 'broken.yaml')
        File.write(broken_path, "version: 1\nrules: [not-a-map]\n")

        open_runtime(rt) do |runtime|
          engine = runtime.approval_engine
          refute_equal good_rev, engine.policy.policy_rev

          # Publish half: a validated document reaches workers on the next pass.
          runtime.adapter.bind_approval_active_policy.write(good_path, good_rev)
          runtime.sync_approval_policy
          assert_equal good_rev, engine.policy.policy_rev

          # Fail-closed half: a pointer whose document cannot load leaves the
          # live rev untouched.
          runtime.adapter.bind_approval_active_policy.write(broken_path, 'never-loaded')
          runtime.sync_approval_policy
          assert_equal good_rev, engine.policy.policy_rev
        end
      end
    end
  end

  def test_approve_reload_publishes_only_valid_documents
    with_runtime do |rt|
      Dir.mktmpdir do |policy_dir|
        good_path = File.join(policy_dir, 'good.yaml')
        File.write(good_path, MINIMAL_POLICY)
        broken_path = File.join(policy_dir, 'broken.yaml')
        File.write(broken_path, "version: 1\ntiers:\n  read: [nope\n")

        out = StringIO.new
        err = StringIO.new
        env = { 'TAMOZ_RUNTIME_DIR' => rt.dir }

        status = Tamoz::Agent::CLI.run(['approve', '--reload', broken_path], out: out, err: err, env: env)
        assert_equal 1, status
        assert_match(/policy rejected/, err.string)
        assert_nil Tamoz::SQLite::Adapter.new(path: File.join(rt.dir, 'runtime.sqlite3')).bind_approval_active_policy.read

        status = Tamoz::Agent::CLI.run(['approve', '--reload', good_path], out: out, err: err, env: env)
        assert_equal 0, status
        pointer = Tamoz::SQLite::Adapter.new(path: File.join(rt.dir, 'runtime.sqlite3')).bind_approval_active_policy.read
        assert_equal good_path, pointer.fetch(:path)
        expected_rev = Tamoz::Approval::PolicyDocument.load(good_path, evidence_symbols: evidence_set).policy_rev
        assert_equal expected_rev, pointer.fetch(:rev)
      end
    end
  end

  def test_session_start_binds_the_live_policy_rev
    with_runtime do |rt|
      open_runtime(rt) do |runtime|
        runtime.canonical_session
        bound = runtime.approval_engine.instance_variable_get(:@session_revs)
        assert_equal runtime.approval_engine.policy.policy_rev, bound.fetch('profile:default')
      end
    end
  end

  private

  def evidence_set
    Tamoz::Comms::AuthorityEvidence.members
  end

  def open_runtime(rt)
    runtime = Tamoz::Agent::WorkerRuntime.open(
      Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
      model_factory: ->(profile:) { read_only_factory.call(profile) }
    )
    yield runtime
  ensure
    runtime&.close
  end

  def override_config(rt, approval)
    config_path = File.join(rt.dir, 'config.yaml')
    document = Psych.load_file(config_path)
    document['approval'] = approval
    File.write(config_path, Psych.dump(document))
  end

  MINIMAL_POLICY = <<~YAML
    version: 1
    tool_tiers:
      run_check:
        tier: local_execute
        verb: execute
        key_argv: [0]
        grant_scopes: [once, session]
    fallback_tier:
      tier: local_execute
      verb: unknown
      grant_scopes: [once]
    tiers:
      read:
        default: allow
      local_execute:
        default: ask
        grant_scopes: [once, session]
    grant_keys:
      local_execute: [verb, tool, target_root, key_argv]
    rules:
      - id: credential-files
        verdict: deny
        match:
          tool: read_file
          target_glob: "**/.env*"
        reason: credential files are outside the agent's read scope
    ask:
      timeout_s: 900
      on_timeout: park
    evidence:
      approve: filesystem_operator
      deny: chat_bound
    simulations:
      - request:
          tool: run_check
          verb: execute
          argv: [lint]
          targets: ["/workspace/src"]
        expect: ask
  YAML
end
