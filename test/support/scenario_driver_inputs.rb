# frozen_string_literal: true

require 'digest'

module ScenarioDriverInputs
  module_function

  def scenario_id = 'T3-m1m2'
  def restart_scenario_id = 'T3-m3m4'
  def mission_id = 'contradictory-observation'
  def restart_mission_id = 'compaction-restart'
  def restart_fixture_path = 'scenario/restart-marker.json'
  def restart_fixture_content = "created after durable restart\n"
  def restart_fixture_mode = '0644'
  def restart_fixture_digest = Digest::SHA256.hexdigest(restart_fixture_content)

  def definitions
    @definitions ||= {
      scenario_id => contradiction_definition,
      restart_scenario_id => restart_definition
    }.freeze
  end

  def contradiction_definition
    {
      'id' => scenario_id,
      'mission_id' => mission_id,
      'driver_mode' => 'contradiction',
      'setup' => {
        'fixture' => { 'path' => 'scenario/status.json', 'status' => 'active' }
      },
      'steps' => contradiction_steps,
      'oracle' => Tamoz::Evals::Benchmark::ScenarioDriver::T3M1M2Oracle
    }
  end

  def contradiction_steps
    [
      {
        'id' => 'M1',
        'task' => 'Determine the correct status from scenario/status.json and record it once. ' \
                  'Reconsider if the evidence changes.'
      },
      {
        'id' => 'M2',
        'fixture' => {
          'path' => 'scenario/status.json', 'status' => 'inactive'
        },
        'task' => 'Reconsider the status after scenario/status.json changed. Re-read it, revise ' \
                  'your decision if needed, and record the corrected status once. Do not rely on ' \
                  'the earlier value.'
      }
    ]
  end

  def restart_definition
    {
      'id' => restart_scenario_id,
      'mission_id' => restart_mission_id,
      'driver_mode' => 'restart',
      'setup' => {
        'fixture' => {
          'path' => restart_fixture_path,
          'content' => restart_fixture_content,
          'expected_sha256' => restart_fixture_digest,
          'mode' => restart_fixture_mode
        }
      },
      'steps' => restart_steps,
      'oracle' => Tamoz::Evals::Benchmark::ScenarioDriver::T3M3M4Oracle
    }
  end

  def restart_steps
    [
      {
        'id' => 'M3',
        'task' => 'Create the restart fixture file using the exact create_file arguments supplied ' \
                  'below. Keep this single create_file request logically stable because the ' \
                  'worker may be interrupted immediately after its effect is journaled. On ' \
                  'restart, resume from the durable checkpoint using the journaled result ' \
                  'without re-journaling the effect, then summarize the recovery.'
      },
      {
        'id' => 'M4',
        'task' => 'After the worker restarts, resume from the durable checkpoint and complete ' \
                  'only from the journaled create_file result. Do not re-journal the effect; ' \
                  'summarize the recovery.'
      }
    ]
  end
end
