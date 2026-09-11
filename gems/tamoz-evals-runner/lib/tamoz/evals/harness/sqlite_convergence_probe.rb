# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteConvergenceProbe
        VERSION = 1
        MAX_PATH_BYTES = 4_096
        MAX_DATABASE_BYTES = 256 * 1024 * 1024
        MAX_LEDGER_BYTES = 1024 * 1024
        # The complete probe surface, declared here rather than derived from the
        # manifest string, so an unknown probe name is refused at construction
        # instead of reaching a missing method at dispatch.
        PROBE_METHODS = {
          "lease-fencing" => :probe_lease_fencing,
          "inbox-reopen" => :probe_inbox_reopen,
          "duplicate-delivery" => :probe_duplicate_delivery,
          "request-recovery" => :probe_request_recovery,
          "stale-request-fail" => :probe_stale_request_fail,
          "pending-write-replay" => :probe_pending_write_replay,
          "checkpoint-reopen" => :probe_checkpoint_reopen,
          "request-checkpoint-reopen" => :probe_request_checkpoint_reopen
        }.freeze

        def initialize(scenario_registry:, definition:, inputs:)
          @definition = DeepFreeze.call(definition)
          @inputs = DeepFreeze.call(inputs)
          unless @inputs.is_a?(Hash)
            raise ExecutionError, "SQLite convergence inputs are invalid"
          end
          @graph_factory = @inputs.fetch(:graph_factory)
          unless @graph_factory.respond_to?(:call)
            raise ExecutionError, "SQLite convergence graph factory is invalid"
          end
          # Guard the probe table BEFORE reading it below: a malformed or absent
          # :probes must fail with this file's ExecutionError, not a bare
          # NoMethodError/KeyError from `probes.keys`.
          unless @inputs[:probes].is_a?(Hash) &&
                 @inputs[:probes].values.all? { |probe| PROBE_METHODS.key?(probe) }
            raise ExecutionError, "SQLite convergence probes are invalid"
          end
          unless scenario_registry.instance_of?(SQLiteScenarioRegistry) &&
                 scenario_registry.document.fetch("scenarios").map do |scenario|
                   scenario.fetch("id")
                 end.sort == probes.keys.sort
            raise ExecutionError,
                  "SQLite convergence scenario registry is incompatible"
          end
          @scenario_registry = scenario_registry
          freeze
        end

        attr_reader :definition

        def digest
          CanonicalJSON.content_digest(
            @definition,
            domain: "eval.sqlite_convergence_probe"
          )
        end

        def run(scenario_id:, classification:, path:, ledger_path: nil)
          primary_error = nil
          validate_capabilities!
          scenario = @scenario_registry.fetch(scenario_id)
          classification = validate_classification!(scenario, classification)
          database_path = validate_path!(path, "database")
          id = scenario.fetch("id")
          probe = probes.fetch(id)
          ledger = resolve_ledger(probe, ledger_path)
          adapter = Tamoz::SQLite::Adapter.new(path: database_path)
          app = graph_definition(ledger).compile(checkpointer: adapter)
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

        def graph_definition(ledger_path)
          recorder = method(:record_invocation!)
          @graph_factory.call(name: graph_name, version: graph_version) do
            recorder.call(ledger_path) if ledger_path
          end
        end

        def record_invocation!(path)
          primary_error = nil
          database = SQLite3::Database.new(path, strict: true)
          database.execute("PRAGMA synchronous = FULL")
          database.execute(
            "INSERT INTO invocations(logical_id) VALUES (?)",
            [ledger_invocation]
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
          probe = probes.fetch(scenario_id)
          method_name = PROBE_METHODS.fetch(probe) do
            raise ExecutionError, "SQLite convergence probe #{probe.inspect} is not implemented"
          end
          send(method_name, app, adapter, scenario_id, classification, ledger)
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
              [thread_id, encoded]
            )
          end
        end

        def stale_lease_record(prior, encoded)
          return unless prior&.fetch(0)

          lease_class = Tamoz::SQLite.const_get(:LeaseRecord, false)
          lease_class.new(
            thread_id: thread_id,
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
            thread_id: thread_id,
            namespace: encoded,
            owner_id: owner_id,
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
            thread: thread_id,
            request_id: request_id
          )
          expected = request_states.fetch(scenario).fetch(classification)
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
          before = runner.fetch(thread: thread_id, request_id: request_id)
          after = runner.submit(
            {},
            thread: thread_id,
            request_id: request_id
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
          before = runner.fetch(thread: thread_id, request_id: request_id)
          unless before && before.execution_id
            raise ExecutionError,
                  "SQLite convergence recovery request is unbound"
          end
          recovered = runner.recover(
            thread: thread_id,
            request_id: request_id,
            owner_id: owner_id
          )
          snapshot = app.state(thread: thread_id)
          expected_history = recovery_history_counts.fetch(scenario)
          history_count = app.history(thread: thread_id).length
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
          request = runner.fetch(thread: thread_id, request_id: request_id)
          expected = request_states.fetch(scenario).fetch(classification)
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
            thread: thread_id,
            request_id: request_id,
            operation: :continue
          )
          recovered = runner.run_next(thread: thread_id, owner_id: owner_id)
          after_count = ledger_count(ledger)
          snapshot = app.state(thread: thread_id)
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
            [ledger_invocation]
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
            checkpoint_states.fetch(scenario).fetch(classification)
          history = app.history(thread: thread_id)
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
              expected_count.zero? ? false : !app.state(thread: thread_id).nil?
          }
        end

        def probe_request_checkpoint_reopen(
          app,
          _adapter,
          scenario,
          classification,
          _ledger
        )
          expected = request_checkpoint_states.fetch(scenario).fetch(classification)
          history = app.history(thread: thread_id)
          request = app.durable_runner.fetch(
            thread: thread_id,
            request_id: request_id
          )
          snapshot = app.state(thread: thread_id)
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
            "definition_digest" => digest,
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

        private

        def probes
          @inputs.fetch(:probes)
        end

        def request_states
          @inputs.fetch(:request_states)
        end

        def checkpoint_states
          @inputs.fetch(:checkpoint_states)
        end

        def request_checkpoint_states
          @inputs.fetch(:request_checkpoint_states)
        end

        def recovery_history_counts
          @inputs.fetch(:recovery_history_counts)
        end

        def identifiers
          @inputs.fetch(:identifiers)
        end

        def thread_id
          identifiers.fetch("thread_id")
        end

        def request_id
          identifiers.fetch("request_id")
        end

        def owner_id
          identifiers.fetch("owner_id")
        end

        def ledger_invocation
          identifiers.fetch("ledger_invocation")
        end

        def graph_name
          @definition.fetch("graph").fetch("name")
        end

        def graph_version
          @definition.fetch("graph").fetch("version")
        end
      end

    end
  end
end
