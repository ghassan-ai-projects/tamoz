# frozen_string_literal: true

require 'digest'
require 'securerandom'

module Tamoz
  module Agent
    class Runtime
      # The one-shot runtime is ephemeral: its receipts live and die with the
      # turn, so it journals through the same EffectDispatcher contract over
      # in-memory records instead of the worker's SQLite engine (the same
      # decision `Tamoz::Agent.build` makes for approvals). Keys are stable
      # within this process only; they never cross journals.
      class EffectsJournal
        LOGICAL_IDENTITY_DOMAIN = "tamoz.agent.runtime.effect.logical.v1\n"
        TERMINAL_STATUSES = %i[succeeded failed unknown].freeze
        MAX_ATTEMPTS = EffectDispatcher::MAX_ATTEMPTS

        Decision = Tamoz::Graph::EffectDecision
        Record = Tamoz::Graph::EffectRecord
        Attempt = Tamoz::Graph::EffectAttempt

        # One dispatcher invocation's immutable inputs, bundled so the private
        # helpers do not re-thread seven keywords.
        Call =
          Data.define(
            :logical_key, :execution_id, :task_id, :call_index, :operation, :safety, :request
          )

        def initialize
          @records = {}
          @monitor = Mutex.new
        end

        # The dispatcher's contract fixes this keyword list — it forwards its
        # nine identity fields; same shape the SQLite journal accepts.
        # rubocop:disable Metrics/ParameterLists
        def logical_identity(
          request_id:, execution_id:, operation:, capability_id:, arguments:,
          authority_revision:, catalog_revision:, iteration:, sub_operation:
        )
          fields = {
            'request_id' => request_id,
            'execution_id' => execution_id,
            'operation' => operation,
            'capability_id' => capability_id,
            'arguments' => arguments,
            'authority_revision' => authority_revision,
            'catalog_revision' => catalog_revision,
            'iteration' => iteration,
            'sub_operation' => sub_operation
          }
          "logical:#{Tamoz::Core.digest(LOGICAL_IDENTITY_DOMAIN, fields).delete_prefix('sha256:')}"
        end
        # rubocop:enable Metrics/ParameterLists

        def logical_key(logical_key) = logical_key

        # The dispatcher's contract fixes this keyword list.
        # rubocop:disable Metrics/ParameterLists
        def prepare(execution_id:, task_id:, call_index:, operation:, safety:, request:,
                    request_id: nil, logical_key:)
          call = Call.new(
            logical_key:, execution_id:, task_id:, call_index:, operation:, safety:, request:
          )
          @monitor.synchronize do
            existing = @records[call.logical_key]
            verify_binding!(existing, call) if existing
            return replay_decision(existing) if existing && terminal_status?(existing.status)

            attempt_number = existing ? existing.current_attempt + 1 : 1
            return exhaust(existing, call.logical_key) if attempt_number > MAX_ATTEMPTS

            existing = abandon_running(existing) if existing
            open_attempt(existing, call)
          end
        end
        # rubocop:enable Metrics/ParameterLists

        def start(key:, attempt_token:)
          @monitor.synchronize do
            record = @records.fetch(key)
            attempt = current_owned_attempt(record, attempt_token)
            raise CheckpointConflictError, 'effect attempt is not prepared' unless attempt.status == :prepared

            started = attempt.with(status: :running, started_at_ms: now_ms)
            @records[key] = replace_current(record, started, status: :running)
          end
        end

        def complete(key:, attempt_token:, status:, result: nil, error: nil)
          status = status.to_sym
          unless TERMINAL_STATUSES.include?(status)
            raise ConfigurationError, "invalid effect completion status #{status.inspect}"
          end

          @monitor.synchronize do
            record = @records.fetch(key)
            attempt = current_owned_attempt(record, attempt_token)
            return record if identical_terminal_receipt?(attempt, status, result, error)
            unless attempt.status == :running
              raise CheckpointConflictError, 'effect completion requires a running attempt'
            end

            completed = attempt.with(
              status:, result:, error:, completed_at_ms: now_ms
            )
            @records[key] = replace_current(record, completed, status:)
          end
        end

        def records = @records.values.freeze

        private

        # A terminal receipt replays its recorded status; the dispatcher projects
        # succeeded, failed, and unknown outcomes separately.
        def replay_decision(record)
          action = record.status == :succeeded ? :return : record.status
          Decision.new(action:, record:, attempt_token: nil)
        end

        def exhaust(record, key)
          closed = close_running(record, :unknown)
          @records[key] = closed
          Decision.new(action: :unknown, record: closed, attempt_token: nil)
        end

        def open_attempt(existing, call)
          token = "attempt-#{SecureRandom.uuid}"
          attempt = build_attempt(call.logical_key, existing ? existing.current_attempt + 1 : 1, token)
          record = build_record(existing, attempt, call)
          @records[call.logical_key] = record
          Decision.new(action: :execute, record:, attempt_token: token)
        end

        def build_attempt(logical_key, attempt_number, token)
          Attempt.new(
            identity: "#{logical_key}/attempt/#{attempt_number}",
            attempt_number:,
            attempt_token: token,
            fence: nil,
            status: :prepared,
            deadline_ms: nil,
            result: nil,
            external_id: nil,
            error: nil,
            prepared_at_ms: now_ms,
            started_at_ms: nil,
            completed_at_ms: nil
          )
        end

        def build_record(existing, attempt, call)
          Record.new(
            key: call.logical_key,
            logical_key: call.logical_key,
            thread_id: 'ephemeral',
            namespace: 'runtime',
            execution_id: call.execution_id,
            task_id: call.task_id,
            call_index: call.call_index,
            operation: call.operation,
            safety: call.safety.to_s,
            status: :prepared,
            request_digest: request_digest(call.request),
            current_attempt: attempt.attempt_number,
            requires_reconciliation: false,
            attempts: append(existing, attempt),
            created_at_ms: existing ? existing.created_at_ms : now_ms,
            updated_at_ms: now_ms
          )
        end

        def abandon_running(record)
          running = current_attempt(record)
          replaced = running.with(status: :abandoned, completed_at_ms: now_ms)
          replace_current(record, replaced, status: :prepared)
        end

        def close_running(record, status)
          running = current_attempt(record)
          replaced = running.with(status:, completed_at_ms: now_ms)
          replace_current(record, replaced, status:)
        end

        def current_attempt(record, attempt_token = nil)
          attempt = record.attempts.fetch(record.current_attempt - 1)
          return attempt if attempt_token.nil? || attempt.attempt_token == attempt_token

          raise CheckpointConflictError, 'effect attempt token is stale or does not own current attempt'
        end

        def current_owned_attempt(record, attempt_token)
          raise CheckpointConflictError, 'effect attempt token is required' if attempt_token.nil?

          current_attempt(record, attempt_token)
        end

        def replace_current(record, attempt, status: record.status)
          attempts = record.attempts.dup
          attempts[record.current_attempt - 1] = attempt
          record.with(attempts:, status:, updated_at_ms: now_ms)
        end

        def identical_terminal_receipt?(attempt, status, result, error)
          terminal_status?(attempt.status) &&
            attempt.status == status && attempt.result == result && attempt.error == error
        end

        def verify_binding!(record, call)
          expected = {
            execution_id: call.execution_id,
            task_id: call.task_id,
            call_index: call.call_index,
            operation: call.operation,
            safety: call.safety.to_s,
            request_digest: request_digest(call.request)
          }
          actual = {
            execution_id: record.execution_id,
            task_id: record.task_id,
            call_index: record.call_index,
            operation: record.operation,
            safety: record.safety,
            request_digest: record.request_digest
          }
          return if actual == expected

          raise CheckpointConflictError, 'effect key is already bound to different semantics'
        end

        def append(existing, attempt)
          existing ? existing.attempts + [attempt] : [attempt]
        end

        def terminal_status?(status) = TERMINAL_STATUSES.include?(status)

        def request_digest(request)
          "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(request))}"
        end

        def now_ms
          Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
        end
      end
    end
  end
end
