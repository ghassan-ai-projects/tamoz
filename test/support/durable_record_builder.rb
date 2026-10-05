# frozen_string_literal: true

require 'securerandom'
require 'tamoz/sqlite'

# Writes durable records only through the public tamoz-sqlite and graph APIs.
class DurableRecordBuilder
  attr_reader :adapter, :path

  def self.open(path)
    builder = new(path)
    return builder unless block_given?

    begin
      yield builder
    ensure
      builder.close
    end
  end

  def initialize(path)
    @path = path
    @adapter = Tamoz::SQLite::Adapter.new(path:)
    @turns = turn_graph.compile(checkpointer: @adapter)
    @pauses = pause_graph.compile(checkpointer: @adapter)
    @failures = failure_graph.compile(checkpointer: @adapter)
    @decisions = @adapter.bind_approval_decision_log
  end

  def completed_turn(thread:, request: "request.#{SecureRandom.hex(4)}")
    @turns.durable_runner.deliver({}, thread:, request_id: request)
  end

  def failed_turn(thread:, request: "request.#{SecureRandom.hex(4)}")
    @failures.durable_runner.deliver({}, thread:, request_id: request)
  end

  def paused_turn(thread:, request: "request.#{SecureRandom.hex(4)}")
    @pauses.durable_runner.deliver({}, thread:, request_id: request)
  end

  def effect(thread:, execution_id:, operation:, outcome:, **details)
    store = @turns.checkpointer
    store.open_writer(thread_id: thread, namespace: [], owner_id: 'builder', ttl: store.writer_ttl) do |writer|
      prepared = writer.effects.prepare(
        execution_id:, task_id: "task.#{SecureRandom.hex(4)}", call_index: 0, operation:,
        safety: :idempotent, request: { 'operation' => operation, 'nonce' => SecureRandom.hex(8) },
        request_id: details[:request_id]
      )
      finish(writer.effects, prepared, outcome:, error: details[:error])
    end
  end

  def approval(verdict:, answer: nil, tool: 'write_file', session: 'interactive', policy_rev: 'rev.1')
    id = "decision.#{SecureRandom.hex(4)}"
    @decisions.append(decision_record(id, verdict:, tool:, session:, policy_rev:))
    if answer
      @decisions.record_resolution(decision_id: id, answer:, scope: 'once', actor_evidence: 'cli_tty', grant: nil)
    end
    id
  end

  def close
    @adapter.close unless @adapter.closed?
  end

  private

  def finish(effects, prepared, outcome:, error:)
    token = prepared.attempt_token
    key = prepared.record.key
    return prepared if outcome == :prepared

    effects.start(key:, attempt_token: token)
    return prepared if outcome == :running

    result = outcome == :succeeded ? { 'ok' => true } : nil
    effects.complete(key:, attempt_token: token, status: outcome, result:, error:)
  end

  def decision_record(id, verdict:, tool:, session:, policy_rev:)
    {
      decision_id: id, session_id: session, tool:, verb: 'write', tier: 'change', rule_id: "rule.#{tool}",
      verdict:, reason: 'policy', evidence: nil, policy_rev:,
      argv_digest: Tamoz::Core.digest("builder.argv\n", id),
      targets_digest: Tamoz::Core.digest("builder.targets\n", id),
      step_scope: '', grant_scopes: nil, grant_key: nil
    }
  end

  def turn_graph
    Tamoz.graph(name: 'builder-turn', version: '1') do
      state :done, default: false
      node(:finish, implementation_name: 'builder.finish', version: '1') { |_state, _context| { done: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  def pause_graph
    Tamoz.graph(name: 'builder-pause', version: '1') do
      state :answers, reduce: :append, default: []
      node(:pause, implementation_name: 'builder.pause', version: '1') do |_state, context|
        { answers: [Tamoz.interrupt({ 'question' => 'approve?' }, context)] }
      end
      edge Tamoz::START, :pause
      edge :pause, Tamoz::END
    end
  end

  def failure_graph
    Tamoz.graph(name: 'builder-failure', version: '1') do
      state :done, default: false
      node(:fail, implementation_name: 'builder.fail', version: '1') do |_state, _context|
        raise ArgumentError, 'builder failure'
      end
      edge Tamoz::START, :fail
      edge :fail, Tamoz::END
    end
  end
end
