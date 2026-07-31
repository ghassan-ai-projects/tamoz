# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteScenarioRuntime
        THREAD_ID = "thread.phase2"
        OWNER_A = "owner.phase2.a"
        OWNER_B = "owner.phase2.b"
        REQUEST_ID = "request.phase2"
        EXECUTION_A = "execution.phase2.a"
        EXECUTION_B = "execution.phase2.b"
        GRAPH_NAME = "tamoz-eval-sqlite-phase2"
        GRAPH_VERSION = "1"

        def initialize(definition:, path:, fault_injector:)
          @definition = definition
          @path = path
          @fault_injector = fault_injector
          @state = :fresh
          @action = nil
          validate_capabilities!
        end

        def setup!
          unless @state == :fresh
            raise ExecutionError, "SQLite scenario setup can run only once"
          end
          @adapter = Tamoz::SQLite::Adapter.new(
            path: @path,
            fault_injector: @fault_injector
          )
          @wire = Tamoz::SQLite.const_get(:Wire, false)
          @namespace = @wire.namespace([])
          @compiled = fixture_definition.compile(checkpointer: @adapter)
          @store = @compiled.checkpointer
          prepare_action!
          unless @action.respond_to?(:call)
            raise ExecutionError, "SQLite scenario action is missing"
          end
          @state = :prepared
          self
        end

        def action!
          unless @state == :prepared
            raise ExecutionError, "SQLite scenario action can run only once"
          end
          @state = :running
          result = @action.call
          @state = :complete
          result
        rescue StandardError
          @state = :failed
          raise
        end

        def close
          @adapter&.close unless @adapter&.closed?
          @state = :closed
          nil
        end

        private

        def validate_capabilities!
          unless defined?(Tamoz::SQLite::Adapter) &&
                 Tamoz.respond_to?(:graph) &&
                 defined?(Tamoz::Graph::Task) &&
                 defined?(Tamoz::END)
            raise ExecutionError,
                  "SQLite scenario runtime capabilities are unavailable"
          end
        end

        def fixture_definition
          Tamoz.graph(name: GRAPH_NAME, version: GRAPH_VERSION) do
            state :value, default: 0
            state :events, reduce: :append, default: []
            node(
              :work,
              implementation_name: "tamoz.eval.sqlite.work",
              version: "1"
            ) { |_state, _context| {value: 1} }
            edge Tamoz::START, :work
            edge :work, Tamoz::END
          end
        end

        def prepare_action!
          case @definition.fetch("id")
          when "lease.acquire-new" then prepare_lease_acquire_new
          when "lease.acquire-takeover" then prepare_lease_acquire_takeover
          when "lease.validate" then prepare_lease_validate
          when "lease.renew" then prepare_lease_renew
          when "lease.release" then prepare_lease_release
          when "request.enqueue-new" then prepare_request_enqueue_new
          when "request.enqueue-duplicate" then prepare_request_enqueue_duplicate
          when "request.claim-turn" then prepare_request_claim_turn
          when "request.claim-resume" then prepare_request_claim_resume
          when "request.claim-redirect" then prepare_request_claim_redirect
          when "request.recover-claimed" then prepare_request_recover_claimed
          when "request.recover-running" then prepare_request_recover_running
          when "request.recover-redirecting" then prepare_request_recover_redirecting
          when "request.mark-running" then prepare_request_mark_running
          when "request.mark-redirect-running"
            prepare_request_mark_redirect_running
          when "request.redirect-ready" then prepare_request_redirect_ready
          when "checkpoint.writes-new" then prepare_checkpoint_writes_new
          when "checkpoint.writes-duplicate"
            prepare_checkpoint_writes_duplicate
          when "checkpoint.commit-start" then prepare_checkpoint_commit_start
          when "checkpoint.commit-advance" then prepare_checkpoint_commit_advance
          when "checkpoint.commit-turn" then prepare_checkpoint_commit_turn
          when "checkpoint.commit-fork" then prepare_checkpoint_commit_fork
          when "checkpoint.commit-paused" then prepare_checkpoint_commit_paused
          when "checkpoint.commit-failed" then prepare_checkpoint_commit_failed
          else
            raise ExecutionError, "SQLite scenario setup is not implemented"
          end
        end

        def prepare_lease_acquire_new
          @action = -> { acquire_lease(OWNER_A) }
        end

        def prepare_lease_acquire_takeover
          lease = acquire_lease(OWNER_A)
          expire_lease!(lease)
          @action = -> { acquire_lease(OWNER_B) }
        end

        def prepare_lease_validate
          lease = acquire_lease(OWNER_A)
          reset_clock_watermark!(lease)
          @action = -> { @adapter.__send__(:validate_lease, lease) }
        end

        def prepare_lease_renew
          lease = acquire_lease(OWNER_A)
          shorten_lease_expiry!(lease)
          @action = -> { @adapter.__send__(:renew_lease, lease) }
        end

        def prepare_lease_release
          lease = acquire_lease(OWNER_A)
          @action = -> { @adapter.__send__(:release_lease, lease) }
        end

        def prepare_request_enqueue_new
          @action = -> { enqueue_request(:turn) }
        end

        def prepare_request_enqueue_duplicate
          enqueue_request(:turn)
          @action = -> { enqueue_request(:turn) }
        end

        def prepare_request_claim_turn
          enqueue_request(:turn)
          lease = acquire_lease(OWNER_A)
          @action = -> { @store.claim_next_request(lease:) }
        end

        def prepare_request_claim_resume
          lease = acquire_lease(OWNER_A)
          commit_start(lease, execution_id: EXECUTION_A)
          enqueue_request(:resume)
          @action = -> { @store.claim_next_request(lease:) }
        end

        def prepare_request_claim_redirect
          lease = acquire_lease(OWNER_A)
          commit_start(lease, execution_id: EXECUTION_A)
          enqueue_request(:redirect, delivery: :redirect)
          @action = -> { @store.claim_next_request(lease:) }
        end

        def prepare_request_recover_claimed
          lease, request = claimed_request(:turn)
          current = takeover_lease(lease)
          @action = lambda do
            @store.recover_request(
              lease: current,
              request_id: request.request_id
            )
          end
        end

        def prepare_request_recover_running
          lease, request = claimed_request(:turn)
          @store.mark_request_running(
            lease:,
            request_id: request.request_id,
            execution_id: request.execution_id
          )
          current = takeover_lease(lease)
          @action = lambda do
            @store.recover_request(
              lease: current,
              request_id: request.request_id
            )
          end
        end

        def prepare_request_recover_redirecting
          lease = acquire_lease(OWNER_A)
          commit_start(lease, execution_id: EXECUTION_A)
          enqueue_request(:redirect, delivery: :redirect)
          request = @store.claim_next_request(lease:)
          current = takeover_lease(lease)
          @action = lambda do
            @store.recover_request(
              lease: current,
              request_id: request.request_id
            )
          end
        end

        def prepare_request_mark_running
          lease, request = claimed_request(:turn)
          @action = lambda do
            @store.mark_request_running(
              lease:,
              request_id: request.request_id,
              execution_id: request.execution_id
            )
          end
        end

        def prepare_request_mark_redirect_running
          lease = acquire_lease(OWNER_A)
          commit_start(lease, execution_id: EXECUTION_A)
          enqueue_request(:redirect, delivery: :redirect)
          request = @store.claim_next_request(lease:)
          @action = lambda do
            @store.mark_request_running(
              lease:,
              request_id: request.request_id,
              execution_id: request.execution_id
            )
          end
        end

        def prepare_request_redirect_ready
          lease = acquire_lease(OWNER_A)
          commit_start(lease, execution_id: EXECUTION_A)
          @action = lambda do
            @store.redirect_ready?(
              lease:,
              target_execution_id: EXECUTION_A
            )
          end
        end

        def prepare_checkpoint_writes_new
          lease = acquire_lease(OWNER_A)
          checkpoint = commit_start(lease, execution_id: EXECUTION_A)
          task, outcome = task_and_outcome(checkpoint)
          @action = lambda do
            @store.append_writes(lease:, task:, outcome:)
          end
        end

        def prepare_checkpoint_writes_duplicate
          lease = acquire_lease(OWNER_A)
          checkpoint = commit_start(lease, execution_id: EXECUTION_A)
          task, outcome = task_and_outcome(checkpoint)
          @store.append_writes(lease:, task:, outcome:)
          @action = lambda do
            @store.append_writes(lease:, task:, outcome:)
          end
        end

        def prepare_checkpoint_commit_start
          lease = acquire_lease(OWNER_A)
          attributes = start_attributes(EXECUTION_A)
          @action = lambda do
            append_checkpoint(
              lease:,
              expected_base_id: nil,
              mode: :start,
              attributes:
            )
          end
        end

        def prepare_checkpoint_commit_advance
          lease = acquire_lease(OWNER_A)
          checkpoint = commit_start(lease, execution_id: EXECUTION_A)
          task, outcome = task_and_outcome(checkpoint)
          @store.append_writes(lease:, task:, outcome:)
          state = @compiled.state_manager.apply_outcomes(
            checkpoint.state,
            [outcome],
            remaining_steps: @compiled.limits.max_steps
          )
          attributes = checkpoint_attributes(
            checkpoint,
            status: :completed,
            logical_step: 1,
            state:,
            frontier: [],
            attempts: {task.id => task.attempt},
            total_tasks: 1
          )
          @action = lambda do
            append_checkpoint(
              lease:,
              expected_base_id: checkpoint.id,
              mode: :advance,
              attributes:,
              consumed_task_ids: [task.id]
            )
          end
        end

        def prepare_checkpoint_commit_turn
          lease = acquire_lease(OWNER_A)
          checkpoint = commit_start(lease, execution_id: EXECUTION_A)
          enqueue_request(:turn)
          request = @store.claim_next_request(lease:)
          transition = @store.request_transition(
            request_id: request.request_id,
            execution_id: request.execution_id,
            action: :completed,
            graph_status: :completed
          )
          attributes = checkpoint_attributes(
            checkpoint,
            execution_id: request.execution_id,
            status: :completed,
            frontier: [],
            attempts: {},
            total_tasks: 0
          )
          @action = lambda do
            append_checkpoint(
              lease:,
              expected_base_id: checkpoint.id,
              mode: :turn,
              attributes:,
              request_transition: transition
            )
          end
        end

        def prepare_checkpoint_commit_fork
          lease = acquire_lease(OWNER_A)
          source = commit_start(lease, execution_id: EXECUTION_A)
          append_checkpoint(
            lease:,
            expected_base_id: source.id,
            mode: :advance,
            attributes: checkpoint_attributes(source, status: :completed, frontier: [])
          )
          attributes = checkpoint_attributes(
            source,
            execution_id: EXECUTION_B,
            status: :completed,
            frontier: [],
            attempts: {},
            total_tasks: 0
          )
          @action = lambda do
            append_checkpoint(
              lease:,
              expected_base_id: source.id,
              mode: :fork,
              attributes:
            )
          end
        end

        def prepare_checkpoint_commit_paused
          lease = acquire_lease(OWNER_A)
          checkpoint = commit_start(lease, execution_id: EXECUTION_A)
          task = @compiled.planner.tasks(checkpoint).first
          interrupt = Tamoz::Graph::Interrupt.new(
            task_id: task.id,
            call_index: 0,
            descriptor: {"question" => "continue"}
          )
          attributes = checkpoint_attributes(
            checkpoint,
            status: :paused,
            interrupts: [interrupt]
          )
          @action = lambda do
            append_checkpoint(
              lease:,
              expected_base_id: checkpoint.id,
              mode: :advance,
              attributes:
            )
          end
        end

        def prepare_checkpoint_commit_failed
          lease = acquire_lease(OWNER_A)
          checkpoint = commit_start(lease, execution_id: EXECUTION_A)
          enqueue_request(:resume)
          request = @store.claim_next_request(lease:)
          transition = @store.request_transition(
            request_id: request.request_id,
            execution_id: request.execution_id,
            action: :failed,
            graph_status: :failed,
            retryable: false
          )
          failure = [
            {
              "graph" => GRAPH_NAME,
              "node" => "work",
              "task_id" => "task.phase2",
              "attempt_id" => "attempt.phase2",
              "error_class" => "ScenarioFailure",
              "safe_message" => "fixed failure"
            }.freeze
          ].freeze
          attributes = checkpoint_attributes(
            checkpoint,
            status: :failed,
            failure:
          )
          @action = lambda do
            append_checkpoint(
              lease:,
              expected_base_id: checkpoint.id,
              mode: :advance,
              attributes:,
              request_transition: transition
            )
          end
        end

        def acquire_lease(owner)
          @adapter.__send__(
            :acquire_lease,
            thread_id: THREAD_ID,
            namespace: @namespace,
            owner_id: owner,
            ttl: @adapter.limits.lease_ttl
          )
        end

        def expire_lease!(lease)
          update_lease_fixture!(
            lease,
            column: "lease_expires_at_ms",
            value: 0,
            operation: "expire_lease"
          )
        end

        def reset_clock_watermark!(lease)
          update_lease_fixture!(
            lease,
            column: "greatest_backend_time_ms",
            value: 0,
            operation: "reset_clock"
          )
        end

        def shorten_lease_expiry!(lease)
          update_lease_fixture!(
            lease,
            column: "lease_expires_at_ms",
            value: lease.expires_at_ms - 1,
            operation: "shorten_lease"
          )
        end

        def update_lease_fixture!(lease, column:, value:, operation:)
          unless %w[
            greatest_backend_time_ms lease_expires_at_ms
          ].include?(column)
            raise ExecutionError, "SQLite fixture lease column is invalid"
          end
          @adapter.__send__(
            :transaction,
            operation: "scenario.fixture.#{operation}"
          ) do |tx|
            tx.execute(
              "scenario.fixture.#{operation}",
              <<~SQL,
                UPDATE tamoz_namespaces
                SET #{column} = ?
                WHERE thread_id = ? AND namespace = ?
                  AND lease_owner_id = ? AND lease_fence = ?
              SQL
              [
                value,
                lease.thread_id,
                lease.namespace,
                lease.owner_id,
                lease.fence
              ]
            )
            unless tx.changes == 1
              raise ExecutionError, "SQLite fixture lease update failed"
            end
          end
        end

        def takeover_lease(lease)
          expire_lease!(lease)
          acquire_lease(OWNER_B)
        end

        def enqueue_request(operation, delivery: :queue)
          @store.enqueue_request(
            thread_id: THREAD_ID,
            namespace: [],
            request_id: REQUEST_ID,
            operation:,
            payload: {},
            delivery:
          )
        end

        def claimed_request(operation)
          enqueue_request(operation)
          lease = acquire_lease(OWNER_A)
          [lease, @store.claim_next_request(lease:)].freeze
        end

        def commit_start(lease, execution_id:)
          append_checkpoint(
            lease:,
            expected_base_id: nil,
            mode: :start,
            attributes: start_attributes(execution_id)
          )
        end

        def append_checkpoint(
          lease:,
          expected_base_id:,
          mode:,
          attributes:,
          consumed_task_ids: [],
          request_transition: nil
        )
          @store.append_checkpoint(
            lease:,
            expected_base_id:,
            mode:,
            attributes:,
            consumed_task_ids:,
            request_transition:
          )
        end

        def start_attributes(execution_id)
          state = @compiled.state_manager.initial(
            {},
            remaining_steps: @compiled.limits.max_steps
          )
          {
            graph_name: GRAPH_NAME,
            graph_version: GRAPH_VERSION,
            definition_digest: @compiled.definition_digest,
            execution_id:,
            status: :running,
            logical_step: 0,
            state:,
            state_bytes: @compiled.state_manager.state_bytes(state),
            frontier: @compiled.route_planner.initial_frontier,
            pending: {}.freeze,
            interrupts: [].freeze,
            resume_values: {}.freeze,
            attempts: {}.freeze,
            failure: nil,
            total_tasks: 0
          }.freeze
        end

        def checkpoint_attributes(
          checkpoint,
          execution_id: checkpoint.execution_id,
          status: checkpoint.status,
          logical_step: checkpoint.logical_step,
          state: checkpoint.state,
          frontier: checkpoint.frontier,
          pending: checkpoint.pending,
          interrupts: checkpoint.interrupts,
          resume_values: checkpoint.resume_values,
          attempts: checkpoint.attempts,
          failure: checkpoint.failure,
          total_tasks: checkpoint.total_tasks
        )
          {
            graph_name: checkpoint.graph_name,
            graph_version: checkpoint.graph_version,
            definition_digest: checkpoint.definition_digest,
            execution_id:,
            status:,
            logical_step:,
            state:,
            state_bytes: @compiled.state_manager.state_bytes(state),
            frontier: Array(frontier).freeze,
            pending: pending.freeze,
            interrupts: Array(interrupts).freeze,
            resume_values: resume_values.freeze,
            attempts: attempts.freeze,
            failure:,
            total_tasks:
          }.freeze
        end

        def task_and_outcome(checkpoint)
          task = @compiled.planner.tasks(checkpoint).first
          unless task
            raise ExecutionError, "SQLite fixture task is missing"
          end
          outcome_class = Tamoz::Graph.const_get(:Outcome, false)
          update = @compiled.state_manager.normalize_update({value: 1})
          outcome = outcome_class.new(
            task_id: task.id,
            attempt_id: task.attempt_id,
            base_checkpoint_id: task.base_checkpoint_id,
            node: task.node,
            path: task.path,
            update:,
            goto: [Tamoz::END]
          )
          [task, outcome].freeze
        end

        private_constant :EXECUTION_A, :EXECUTION_B, :GRAPH_NAME,
                         :GRAPH_VERSION, :OWNER_A, :OWNER_B, :REQUEST_ID,
                         :THREAD_ID
      end

      private_constant :SQLiteScenarioRuntime
    end
  end
end
