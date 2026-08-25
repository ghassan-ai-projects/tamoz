# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteConvergenceProbe
        VERSION = 1
        MAX_PATH_BYTES = 4_096
        MAX_DATABASE_BYTES = 256 * 1024 * 1024
        MAX_LEDGER_BYTES = 1024 * 1024
        THREAD_ID = "thread.phase2"
        REQUEST_ID = "request.phase2"
        OWNER_ID = "owner.phase2.convergence"
        LEDGER_INVOCATION = "work.phase2"
        GRAPH_NAME = "tamoz-eval-sqlite-phase2"
        GRAPH_VERSION = "1"

        PROBES = DeepFreeze.call(
          {
            "lease.acquire-new" => "lease-fencing",
            "lease.acquire-takeover" => "lease-fencing",
            "lease.validate" => "lease-fencing",
            "lease.renew" => "lease-fencing",
            "lease.release" => "lease-fencing",
            "request.enqueue-new" => "inbox-reopen",
            "request.enqueue-duplicate" => "duplicate-delivery",
            "request.claim-turn" => "inbox-reopen",
            "request.claim-resume" => "inbox-reopen",
            "request.claim-redirect" => "inbox-reopen",
            "request.claim-stale" => "stale-request-fail",
            "request.recover-claimed" => "request-recovery",
            "request.recover-running" => "request-recovery",
            "request.recover-redirecting" => "request-recovery",
            "request.recover-stale" => "stale-request-fail",
            "request.mark-running" => "inbox-reopen",
            "request.mark-redirect-running" => "inbox-reopen",
            "request.redirect-ready" => "checkpoint-reopen",
            "checkpoint.writes-new" => "pending-write-replay",
            "checkpoint.writes-duplicate" => "pending-write-replay",
            "checkpoint.commit-start" => "checkpoint-reopen",
            "checkpoint.commit-advance" => "checkpoint-reopen",
            "checkpoint.commit-turn" => "request-checkpoint-reopen",
            "checkpoint.commit-fork" => "checkpoint-reopen",
            "checkpoint.commit-paused" => "checkpoint-reopen",
            "checkpoint.commit-failed" => "request-checkpoint-reopen"
          }
        )
        REQUEST_STATES = DeepFreeze.call(
          {
            "request.enqueue-new" => {"old" => nil, "new" => "queued"},
            "request.claim-turn" => {"old" => "queued", "new" => "claimed"},
            "request.claim-resume" => {"old" => "queued", "new" => "claimed"},
            "request.claim-redirect" => {
              "old" => "queued",
              "new" => "redirecting"
            },
            "request.claim-stale" => {"old" => "queued", "new" => "failed"},
            "request.recover-stale" => {"old" => "claimed", "new" => "failed"},
            "request.mark-running" => {
              "old" => "claimed",
              "new" => "running"
            },
            "request.mark-redirect-running" => {
              "old" => "redirecting",
              "new" => "running"
            }
          }
        )
        CHECKPOINT_STATES = DeepFreeze.call(
          {
            "request.redirect-ready" => {
              "stable" => [1, "running"]
            },
            "checkpoint.commit-start" => {
              "old" => [0, nil],
              "new" => [1, "running"]
            },
            "checkpoint.commit-advance" => {
              "old" => [1, "running"],
              "new" => [2, "completed"]
            },
            "checkpoint.commit-fork" => {
              "old" => [2, "completed"],
              "new" => [3, "completed"]
            },
            "checkpoint.commit-paused" => {
              "old" => [1, "running"],
              "new" => [2, "paused"]
            }
          }
        )
        REQUEST_CHECKPOINT_STATES = DeepFreeze.call(
          {
            "checkpoint.commit-turn" => {
              "old" => [1, "running", "claimed"],
              "new" => [2, "completed", "completed"]
            },
            "checkpoint.commit-failed" => {
              "old" => [1, "running", "claimed"],
              "new" => [2, "failed", "failed"]
            }
          }
        )
        RECOVERY_HISTORY_COUNTS = DeepFreeze.call(
          {
            "request.recover-claimed" => 2,
            "request.recover-running" => 2,
            "request.recover-redirecting" => 3
          }
        )
        DEFINITION = DeepFreeze.call(
          {
            "id" => "tamoz.sqlite.convergence_probe",
            "version" => VERSION,
            "scenario_probes" => PROBES,
            "classification_precondition" =>
              "independent-oracle-complete-state-only",
            "process_policy" => "caller-must-spawn-fresh-process",
            "lease_policy" => "classified-copy-with-expiry-elision",
            "ledger_policy" =>
              "separate-synchronous-full-unique-logical-invocation",
            "fixture_graph" => {
              "name" => GRAPH_NAME,
              "version" => GRAPH_VERSION,
              "channels" => %w[value events],
              "nodes" => ["work"]
            },
            "output_policy" =>
              "canonical-bounded-facts-without-path-owner-or-raw-identity"
          }
        )
        DEFINITION_DIGEST = CanonicalJSON.content_digest(
          DEFINITION,
          domain: "eval.sqlite_convergence_probe"
        ).freeze

        class << self
          def definition
            DEFINITION
          end

          def digest
            DEFINITION_DIGEST
          end
        end

        def initialize(scenario_registry:)
          unless scenario_registry.instance_of?(SQLiteScenarioRegistry) &&
                 scenario_registry.document.fetch("scenarios").map do |scenario|
                   scenario.fetch("id")
                 end.sort == PROBES.keys.sort
            raise ExecutionError,
                  "SQLite convergence scenario registry is incompatible"
          end
          @scenario_registry = scenario_registry
          freeze
        end

        def run(scenario_id:, classification:, path:, ledger_path: nil)
          primary_error = nil
          validate_capabilities!
          scenario = @scenario_registry.fetch(scenario_id)
          classification = validate_classification!(scenario, classification)
          database_path = validate_path!(path, "database")
          id = scenario.fetch("id")
          probe = PROBES.fetch(id)
          ledger = resolve_ledger(probe, ledger_path)
          adapter = Tamoz::SQLite::Adapter.new(path: database_path)
          app = fixture_definition(ledger).compile(checkpointer: adapter)
          facts = execute_probe(app:, adapter:, scenario_id: id, classification:, ledger:)
          build_report(scenario: id, classification:, probe:, facts:)
        rescue KeyError, TypeError => error
          primary_error = error
          raise ExecutionError.new(
            "SQLite convergence input is invalid"
          ), cause: error
        rescue StandardError => error
          primary_error = error
          raise
        ensure
          begin
            adapter&.close unless adapter&.closed?
          rescue StandardError
            raise unless primary_error
          end
        end

        private

        def validate_capabilities!
          unless defined?(Tamoz::SQLite::Adapter) &&
                 defined?(SQLite3::Database) &&
                 Tamoz.respond_to?(:graph) &&
                 defined?(Tamoz::END)
            raise ExecutionError,
                  "SQLite convergence runtime capabilities are unavailable"
          end
        end

        def validate_classification!(scenario, value)
          unless value.is_a?(String) &&
                 scenario.fetch("state_classes").include?(value)
            raise ExecutionError,
                  "SQLite convergence classification is invalid"
          end
          value.dup.freeze
        end

        def validate_path!(value, name)
          validate_path_shape!(value, name)
          enforce_path_safety!(value, name)
          value.dup.freeze
        end

        def validate_path_shape!(value, name)
          unless value.is_a?(String) &&
                 value.valid_encoding? &&
                 !value.empty? &&
                 value.bytesize <= MAX_PATH_BYTES &&
                 File.absolute_path(value) == value
            raise ExecutionError, "SQLite convergence #{name} path is invalid"
          end
        end

        def enforce_path_safety!(value, name)
          stat = File.lstat(value)
          parent = File.lstat(File.dirname(value))
          maximum = name == "database" ? MAX_DATABASE_BYTES : MAX_LEDGER_BYTES
          unless stat.file? &&
                 stat.uid == Process.euid &&
                 stat.nlink == 1 &&
                 (stat.mode & 0o077).zero? &&
                 stat.size <= maximum &&
                 parent.directory? &&
                 parent.uid == Process.euid &&
                 (parent.mode & 0o077).zero?
            raise ExecutionError, "SQLite convergence #{name} path is unsafe"
          end
        rescue Errno::ENOENT, Errno::ELOOP => error
          raise ExecutionError.new(
            "SQLite convergence #{name} path is invalid"
          ), cause: error
        end

        def resolve_ledger(probe, ledger_path)
          if probe == "pending-write-replay"
            validate_path!(ledger_path, "ledger")
          elsif ledger_path.nil?
            nil
          else
            raise ExecutionError,
                  "SQLite convergence ledger is unexpected"
          end
        end

        def fixture_definition(ledger_path)
          recorder = method(:record_invocation!)
          Tamoz.graph(name: GRAPH_NAME, version: GRAPH_VERSION) do
            state :value, default: 0
            state :events, reduce: :append, default: []
            node(
              :work,
              implementation_name: "tamoz.eval.sqlite.work",
              version: "1"
            ) do |_state, _context|
              recorder.call(ledger_path) if ledger_path
              {value: 1}
            end
            edge Tamoz::START, :work
            edge :work, Tamoz::END
          end
        end

        def record_invocation!(path)
          primary_error = nil
          database = SQLite3::Database.new(path, strict: true)
          database.execute("PRAGMA synchronous = FULL")
          database.execute(
            "INSERT INTO invocations(logical_id) VALUES (?)",
            [LEDGER_INVOCATION]
          )
        rescue StandardError => error
          primary_error = error
          raise
        ensure
          begin
            database&.close
          rescue StandardError
            raise unless primary_error
          end
        end

        def execute_probe(app:, adapter:, scenario_id:, classification:, ledger:)
          probe = PROBES.fetch(scenario_id)
          send(
            "probe_#{probe.tr("-", "_")}",
            app,
            adapter,
            scenario_id,
            classification,
            ledger
          )
        end

        def probe_lease_fencing(_app, adapter, _scenario, _classification, _ledger)
          encoded = Tamoz::SQLite.const_get(:Wire, false).namespace([])
          prior = read_prior_lease(adapter, encoded)
          prior_fence = prior ? prior.fetch(1) : 0
          stale = stale_lease_record(prior, encoded)
          current = acquire_convergence_lease(adapter, encoded)
          assert_fence_advanced!(current, prior_fence)
          stale_fenced = stale && stale_lease_fenced?(adapter, stale)
          unless stale.nil? || stale_fenced
            raise ExecutionError, "SQLite convergence stale lease remained valid"
          end
          released = adapter.__send__(:release_lease, current)
          unless released
            raise ExecutionError, "SQLite convergence lease release failed"
          end
          {
            "prior_fence" => prior_fence,
            "new_fence" => current.fence,
            "stale_lease_checked" => !stale.nil?,
            "stale_lease_fenced" => stale_fenced
          }
        end

        def read_prior_lease(adapter, encoded)
          adapter.__send__(:read, operation: "eval.convergence.lease") do |tx|
            tx.first(
              "eval.convergence.lease",
              <<~SQL,
                SELECT lease_owner_id, lease_fence, lease_expires_at_ms
                FROM tamoz_namespaces
                WHERE thread_id = ? AND namespace = ?
              SQL
              [THREAD_ID, encoded]
            )
          end
        end

        def stale_lease_record(prior, encoded)
          return unless prior&.fetch(0)

          lease_class = Tamoz::SQLite.const_get(:LeaseRecord, false)
          lease_class.new(
            thread_id: THREAD_ID,
            namespace: encoded,
            owner_id: prior.fetch(0),
            fence: prior.fetch(1),
            expires_at_ms: prior.fetch(2),
            ttl: 30.0
          )
        end

        def acquire_convergence_lease(adapter, encoded)
          adapter.__send__(
            :acquire_lease,
            thread_id: THREAD_ID,
            namespace: encoded,
            owner_id: OWNER_ID,
            ttl: adapter.limits.lease_ttl
          )
        end

        def assert_fence_advanced!(current, prior_fence)
          return if current.fence == prior_fence + 1

          raise ExecutionError, "SQLite convergence fence did not advance"
        end

        def stale_lease_fenced?(adapter, stale)
          adapter.__send__(:validate_lease, stale)
          false
        rescue Tamoz::LeaseLostError
          true
        end

        def probe_inbox_reopen(app, _adapter, scenario, classification, _ledger)
          request = app.durable_runner.fetch(
            thread: THREAD_ID,
            request_id: REQUEST_ID
          )
          expected = REQUEST_STATES.fetch(scenario).fetch(classification)
          actual = request&.status&.to_s
          expected_bound = %w[claimed redirecting running].include?(expected)
          actual_bound = !request&.execution_id.nil?
          unless actual == expected && actual_bound == expected_bound
            raise ExecutionError,
                  "SQLite convergence request state is inconsistent"
          end
          {
            "request_present" => !request.nil?,
            "request_status" => actual,
            "execution_bound" => actual_bound
          }
        end

        def probe_duplicate_delivery(app, _adapter, _scenario, _classification, _ledger)
          runner = app.durable_runner
          before = runner.fetch(thread: THREAD_ID, request_id: REQUEST_ID)
          after = runner.submit(
            {},
            thread: THREAD_ID,
            request_id: REQUEST_ID
          )
          unless before &&
                 before.status == :queued &&
                 after.status == :queued &&
                 before.input_digest == after.input_digest &&
                 before.enqueue_sequence == after.enqueue_sequence
            raise ExecutionError,
                  "SQLite convergence duplicate delivery changed its binding"
          end
          {
            "request_status" => after.status.to_s,
            "same_input_digest" => true,
            "same_enqueue_sequence" => true
          }
        end

        def probe_request_recovery(app, _adapter, scenario, _classification, _ledger)
          runner = app.durable_runner
          before = runner.fetch(thread: THREAD_ID, request_id: REQUEST_ID)
          unless before && before.execution_id
            raise ExecutionError,
                  "SQLite convergence recovery request is unbound"
          end
          recovered = runner.recover(
            thread: THREAD_ID,
            request_id: REQUEST_ID,
            owner_id: OWNER_ID
          )
          snapshot = app.state(thread: THREAD_ID)
          expected_history = RECOVERY_HISTORY_COUNTS.fetch(scenario)
          history_count = app.history(thread: THREAD_ID).length
          unless recovered.status == :completed &&
                 recovered.execution_id == before.execution_id &&
                 snapshot.status == :completed &&
                 snapshot.execution_id == before.execution_id &&
                 snapshot.state.fetch(:value) == 1 &&
                 history_count == expected_history
            raise ExecutionError,
                  "SQLite convergence recovery did not complete"
          end
          {
            "request_status" => recovered.status.to_s,
            "checkpoint_status" => snapshot.status.to_s,
            "execution_preserved" => true,
            "history_count" => history_count
          }
        end

        # DR-4: a stale request terminal-failed at claim or recover is a durable
        # failed request carrying the typed terminal payload and a claim-time
        # execution binding; it is never re-claimable.
        def probe_stale_request_fail(app, _adapter, scenario, classification, _ledger)
          runner = app.durable_runner
          request = runner.fetch(thread: THREAD_ID, request_id: REQUEST_ID)
          expected = REQUEST_STATES.fetch(scenario).fetch(classification)
          unless request && request.status.to_s == expected
            raise ExecutionError,
                  "SQLite convergence stale-fail state is inconsistent"
          end
          if classification == "new"
            unless request.terminal_error.is_a?(Hash) &&
                   request.terminal_error.fetch("graph_status") == "failed" &&
                   !request.terminal_error.fetch("reason").to_s.empty? &&
                   request.execution_id
              raise ExecutionError,
                    "SQLite convergence stale-fail state is inconsistent"
            end
          end
          {
            "request_status" => request.status.to_s,
            "terminal_reason" =>
              request.terminal_error.is_a?(Hash) ?
                request.terminal_error.fetch("reason") : nil,
            "execution_bound" => !request.execution_id.nil?
          }
        end

        def probe_pending_write_replay(app, _adapter, _scenario, classification, ledger)
          expected_before = classification == "old" ? 0 : 1
          before_count = ledger_count(ledger)
          unless before_count == expected_before
            raise ExecutionError,
                  "SQLite convergence ledger precondition is invalid"
          end
          runner = app.durable_runner
          runner.submit(
            {},
            thread: THREAD_ID,
            request_id: REQUEST_ID,
            operation: :continue
          )
          recovered = runner.run_next(thread: THREAD_ID, owner_id: OWNER_ID)
          after_count = ledger_count(ledger)
          snapshot = app.state(thread: THREAD_ID)
          unless recovered&.status == :completed &&
                 snapshot.status == :completed &&
                 snapshot.state.fetch(:value) == 1 &&
                 after_count == 1
            raise ExecutionError,
                  replay_failure_message(recovered, snapshot, after_count)
          end
          {
            "ledger_before" => before_count,
            "ledger_after" => after_count,
            "request_status" => recovered.status.to_s,
            "checkpoint_status" => snapshot.status.to_s
          }
        end

        def replay_failure_message(recovered, snapshot, after_count)
          [
            "SQLite convergence pending write replay failed",
            "request=#{recovered&.status || "missing"}",
            "checkpoint=#{snapshot.status}",
            "value=#{snapshot.state.fetch(:value)}",
            "ledger=#{after_count}"
          ].join(" ")
        end

        def ledger_count(path)
          database = SQLite3::Database.new(path, readonly: true, strict: true)
          schema = database.get_first_value(
            <<~SQL
              SELECT sql
              FROM sqlite_schema
              WHERE type = 'table' AND name = 'invocations'
            SQL
          )
          unless schema ==
                 "CREATE TABLE invocations(logical_id TEXT PRIMARY KEY) STRICT"
            raise ExecutionError,
                  "SQLite convergence ledger schema is invalid"
          end
          value = database.get_first_value(
            "SELECT COUNT(*) FROM invocations WHERE logical_id = ?",
            [LEDGER_INVOCATION]
          )
          unless value.is_a?(Integer) && value.between?(0, 1)
            raise ExecutionError, "SQLite convergence ledger is invalid"
          end
          value
        ensure
          database&.close
        end

        def probe_checkpoint_reopen(app, _adapter, scenario, classification, _ledger)
          expected_count, expected_status =
            CHECKPOINT_STATES.fetch(scenario).fetch(classification)
          history = app.history(thread: THREAD_ID)
          actual_status = history.first&.status&.to_s
          unless history.length == expected_count &&
                 actual_status == expected_status
            raise ExecutionError,
                  "SQLite convergence checkpoint history is inconsistent"
          end
          {
            "history_count" => history.length,
            "checkpoint_status" => actual_status,
            "state_materialized" =>
              expected_count.zero? ? false : !app.state(thread: THREAD_ID).nil?
          }
        end

        def probe_request_checkpoint_reopen(
          app,
          _adapter,
          scenario,
          classification,
          _ledger
        )
          expected = REQUEST_CHECKPOINT_STATES.fetch(scenario).fetch(classification)
          history = app.history(thread: THREAD_ID)
          request = app.durable_runner.fetch(
            thread: THREAD_ID,
            request_id: REQUEST_ID
          )
          snapshot = app.state(thread: THREAD_ID)
          unless request_checkpoint_relation_consistent?(
            history_length: history.length,
            snapshot:,
            request:,
            expected:
          )
            raise ExecutionError,
                  "SQLite convergence request/checkpoint relation is inconsistent"
          end
          {
            "history_count" => history.length,
            "checkpoint_status" => snapshot.status.to_s,
            "request_status" => request.status.to_s,
            "terminal_relation" =>
              request.terminal? && request.checkpoint_id == snapshot.checkpoint_id
          }
        end

        def request_checkpoint_relation_consistent?(
          history_length:,
          snapshot:,
          request:,
          expected:
        )
          expected_count, checkpoint_status, request_status = expected
          history_length == expected_count &&
            snapshot.status.to_s == checkpoint_status &&
            request&.status&.to_s == request_status &&
            (request.checkpoint_id.nil? ||
             request.execution_id == snapshot.execution_id)
        end

        def build_report(scenario:, classification:, probe:, facts:)
          body = {
            "convergence_version" => VERSION,
            "definition_digest" => DEFINITION_DIGEST,
            "scenario" => scenario,
            "classification" => classification,
            "probe" => probe,
            "result" => "passed",
            "facts" => facts,
            "content_digest" => "pending"
          }
          body["content_digest"] = CanonicalJSON.content_digest(
            body,
            domain: "eval.sqlite_convergence_report"
          )
          DeepFreeze.call(body)
        end

        private_constant :CHECKPOINT_STATES, :DEFINITION, :DEFINITION_DIGEST,
                         :GRAPH_NAME, :GRAPH_VERSION, :LEDGER_INVOCATION,
                         :MAX_DATABASE_BYTES, :MAX_LEDGER_BYTES, :MAX_PATH_BYTES,
                         :OWNER_ID, :PROBES, :RECOVERY_HISTORY_COUNTS,
                         :REQUEST_CHECKPOINT_STATES,
                         :REQUEST_ID, :REQUEST_STATES, :THREAD_ID
      end

      private_constant :SQLiteConvergenceProbe
    end
  end
end
