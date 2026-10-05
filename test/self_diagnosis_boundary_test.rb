# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'
require 'tamoz/agent_cli'

class SelfDiagnosisBoundaryTest < Minitest::Test
  OBSERVABILITY = %w[diagnosis.rb diagnosis/rules.rb diagnosis/finding.rb diagnosis/detectors.rb diagnosis/summary.rb
                     diagnosis/report.rb diagnosis/markdown.rb explanation.rb timeline.rb postmortem.rb].map do |file|
    ROOT.join('gems/tamoz-observability/lib/tamoz/observability', file)
  end.freeze
  READER = ROOT.join('gems/tamoz-sqlite/lib/tamoz/sqlite/record_reader.rb')
  READING_SIDE = [ROOT.join('gems/tamoz-agent/lib/tamoz/agent/self_observation.rb'),
                  ROOT.join('gems/tamoz-agent-cli/lib/tamoz/agent/mcp_server.rb')].freeze
  ACTING = /Adapter\.new|open_writer|enqueue|submit|EffectDispatcher|Net::HTTP|Socket|IO\.popen|system\(|spawn|
            AtomicFile|File\.write|\.execute\(|Recorder::Journal\.new|durable_runner/x
  SECRET = "sk-#{'z' * 32}".freeze

  def test_the_pure_modules_reference_no_store_and_no_actor
    OBSERVABILITY.each do |path|
      source = File.read(path, encoding: Encoding::UTF_8)

      refute_match ACTING, source, path.to_s
      refute_match(/Tamoz::SQLite|SQLite3/, source, path.to_s)
    end
  end

  def test_the_reader_is_read_only_and_does_not_know_observability
    source = File.read(READER, encoding: Encoding::UTF_8)

    refute_match(/\b(INSERT|UPDATE|DELETE|REPLACE|CREATE|DROP|ALTER)\b/, source)
    refute_match(/Observability/, source)
    assert source.include?('readonly: true') && source.include?('PRAGMA query_only = ON')
  end

  def test_the_reading_side_reads_through_the_reader_only
    READING_SIDE.each do |path|
      source = File.read(path, encoding: Encoding::UTF_8)

      refute_match ACTING, source, path.to_s
      refute_match(/SQLite3::/, source, path.to_s)
      assert_includes source, 'RecordReader' if path.basename.to_s == 'self_observation.rb'
    end
  end

  def test_a_secret_shaped_value_reaches_no_report_explanation_timeline_postmortem_or_tool_result
    Dir.mktmpdir('tamoz-redaction') do |directory|
      File.chmod(0o700, directory)
      seed_secret_records(directory)
      outputs = secret_outputs(directory)

      outputs.each { |output| refute_includes output, SECRET }
      assert(outputs.any? { |output| output.include?('[REDACTED]') })
    end
  end

  private

  def seed_secret_records(directory)
    DurableRecordBuilder.open(File.join(directory, 'runtime.sqlite3')) do |builder|
      turn = builder.completed_turn(thread: SECRET)
      3.times do
        builder.effect(thread: SECRET, execution_id: turn.execution_id, operation: 'model.generate.plan',
                       outcome: :failed, error: { 'class' => 'Tamoz::Agent::ModelCallError', 'message' => SECRET })
      end
    end
    document = { 'name' => 'tamoz.worker.error', 'kind' => 'event', 'observed_at_ms' => now_ms,
                 'attributes' => { 'reason' => SECRET }, 'correlation' => { 'thread_id' => SECRET } }
    File.write(File.join(directory, 'worker-1.ndjson'), "#{JSON.generate(document)}\n")
  end

  def secret_outputs(directory)
    observation = Tamoz::Agent::SelfObservation.open(runtime_dir: directory)
    now = now_ms
    [observation.diagnose(now_ms: now, since_ms: now - 3_600_000).to_json,
     JSON.generate(observation.explain(thread: SECRET, now_ms: 0)),
     JSON.generate(observation.timeline(since_ms: now - 3_600_000, until_ms: now)),
     Tamoz::Observability::Postmortem.to_markdown(
       observation.postmortem(title: SECRET, now_ms: now, since_ms: now - 3_600_000, until_ms: now)
     ),
     Tamoz::Agent::MCPServer.new(runtime_dir: directory, session_dir: nil).call('observe_diagnose', {}).first]
  end

  def now_ms = (Time.now.to_f * 1000).to_i
end
