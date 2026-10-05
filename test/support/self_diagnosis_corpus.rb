# frozen_string_literal: true

require 'json'
require_relative 'durable_record_builder'

module SelfDiagnosisCorpus
  PATH = File.expand_path('../fixtures/self_diagnosis/scenarios.json', __dir__)
  DIGEST_DOMAIN = "tamoz.test.self_diagnosis.corpus\n"

  module_function

  def load = JSON.parse(File.read(PATH, encoding: Encoding::UTF_8))

  def digest = Tamoz::Core.digest(DIGEST_DOMAIN, load)

  def scenario(id) = load.fetch('scenarios').find { |entry| entry.fetch('id') == id } || raise(KeyError, id)

  def build(scenario, directory, noise: load.fetch('noise'))
    DurableRecordBuilder.open(File.join(directory, 'runtime.sqlite3')) do |builder|
      executions = healthy_noise(builder, noise)
      scenario.fetch('faults').each { |fault| inject(builder, directory, executions, fault) }
    end
  end

  def healthy_noise(builder, noise)
    executions = Array.new(noise.fetch('turns')) do |index|
      turn = builder.completed_turn(thread: "thread.noise.#{index}")
      noise.fetch('model_calls_per_turn').times { succeed(builder, turn, 'model.generate.plan') }
      noise.fetch('tool_calls_per_turn').times { succeed(builder, turn, 'tool.read_file') }
      builder.approval(verdict: 'ask', answer: 'approve', session: 'profile:default')
      [turn.thread_id, turn.execution_id]
    end
    executions
  end

  def succeed(builder, turn, operation)
    builder.effect(thread: turn.thread_id, execution_id: turn.execution_id, operation:, outcome: :succeeded)
  end

  def inject(builder, directory, executions, fault)
    case fault.fetch('kind')
    when 'effect' then inject_effects(builder, executions, fault)
    when 'failed_turn' then fault.fetch('count').times { |index| builder.failed_turn(thread: "thread.failed.#{index}") }
    when 'approval' then fault.fetch('count').times { builder.approval(verdict: fault.fetch('verdict')) }
    when 'journal_event' then journal_events(directory, fault)
    when 'journal_drops' then journal_drops(directory, fault)
    else raise ArgumentError, "unknown fault kind #{fault.fetch('kind')}"
    end
  end

  def inject_effects(builder, executions, fault)
    targets = fault['spread'] ? executions.first(executions.length - 1) : [executions.last]
    fault.fetch('count').times do |index|
      thread, execution = targets[index % targets.length]
      builder.effect(thread:, execution_id: execution, operation: fault.fetch('operation'),
                     outcome: fault.fetch('outcome').to_sym, error: fault['error'])
    end
  end

  def journal_events(directory, fault)
    recorder = Tamoz::Observability::Recorder::Journal.new(directory:, role: 'worker')
    producer = Tamoz::Observability::Producer.new(recorder:)
    fault.fetch('count').times do
      producer.emit(fault.fetch('name'), attributes: { reason: fault.fetch('reason') })
    end
    recorder.flush(deadline_ms: 2_000)
    recorder.close
  end

  def journal_drops(directory, fault)
    path = File.join(directory, "worker-#{Process.pid}.ndjson.health.json")
    File.write(path, JSON.generate('drops' => { fault.fetch('key') => fault.fetch('count') }))
    File.chmod(0o600, path)
  end
end
