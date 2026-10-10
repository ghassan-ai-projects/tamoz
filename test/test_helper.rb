# frozen_string_literal: true

require_relative 'support/simplecov_setup' if ENV['RUN_COVERAGE'] == '1'

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "stringio"
require "tmpdir"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
GEM_ROOTS = %w[tamoz-cancellation tamoz-concurrency tamoz-core tamoz-context-engine tamoz-harness tamoz-research tamoz-graph tamoz-sqlite tamoz-skills tamoz-tools tamoz-agent-kernel tamoz-agent-memory tamoz-agent-healing tamoz-agent-profile tamoz-agent-capabilities tamoz-agent-session tamoz-agent-improvement tamoz-agent-cli tamoz-agent tamoz-approval tamoz-evals tamoz-evals-runner tamoz-mcp tamoz-mcp-websearch tamoz-scheduler tamoz-stream tamoz-comms tamoz-comms-gateway tamoz-telegram tamoz-talk tamoz-observability tamoz-otel].to_h do |name|
  [name, ROOT.join("gems", name)]
end.freeze

GEM_ROOTS.each_value do |root|
  $LOAD_PATH.unshift(root.join("lib").to_s)
end

# Load-path arguments for ruby child processes spawned by tests: every gem
# lib, so extracting a class into a new gem cannot stale-date a spawn.
SUBPROCESS_LIB_ARGS = (
  ["-I", ROOT.join("test").to_s] +
  GEM_ROOTS.values.flat_map { |root| ["-I", root.join("lib").to_s] }
).freeze

require "tamoz/cancellation"
require "tamoz/concurrency"
require "tamoz/core"
require "tamoz/context_engine"
require "tamoz/harness"
require "tamoz/research"
require "tamoz/graph"
require "tamoz/sqlite"
require "tamoz/skills"
require "tamoz/tools"
require "tamoz/agent"
require "tamoz/agent_cli"
require "tamoz/approval"
require "tamoz/evals"
require "tamoz/evals/runner"
require_relative "support/agent_smoke_corpus"
require_relative "support/agent_memory_corpus"
require_relative "support/agent_memory_repository_corpus"
require_relative "support/openclaw_comms_fixture"
require_relative "support/runner_inputs"
require_relative "support/openclaw_comms_runner"
require_relative "support/comms_runtime_profile"
require_relative "support/scenario_driver"
require_relative "support/sqlite_harness_inputs"
require_relative "support/scenario_driver_inputs"
Tamoz::Evals::Runner::InputAdapters.openclaw_fixture_factory = lambda do
  Tamoz::Evals::Benchmark::OpenclawCommsFixture
end
require "tamoz/mcp"
require "tamoz/mcp/websearch"
require "tamoz/scheduler"
require "tamoz/stream"
require "tamoz/comms"
require "tamoz/comms/gateway"
require "tamoz/telegram"
require "tamoz/talk"
require "tamoz/observability"
require "tamoz/otel"

module ArtifactHelpers
  def read_json(path)
    JSON.parse(File.read(path, encoding: Encoding::UTF_8))
  end

  def write_artifact(path, document, domain:)
    document["content_digest"] = Tamoz::Evals::CanonicalJSON.content_digest(document, domain:)
    File.write(
      path,
      "#{Tamoz::Evals::CanonicalJSON.dump(document)}\n",
      encoding: Encoding::UTF_8
    )
  end
end

module AtomicWrites
  Recorder = Module.new do
    def replace(path, bytes, **) = AtomicWrites.note(:replace, path, **) { super }
    def create(path, bytes, **, &) = AtomicWrites.note(:create, path, **) { super }
  end
  Tamoz::Core::AtomicFile.singleton_class.prepend(Recorder)

  class << self
    attr_accessor :log

    def note(operation, path, mode: nil, **)
      log&.push([operation, path.to_s, mode])
      yield
    end
  end

  def atomic_writes
    AtomicWrites.log = []
    yield
    AtomicWrites.log
  ensure
    AtomicWrites.log = nil
  end

  def lock_held_during_atomic_writes(lock_path)
    held = []
    probe = Object.new
    probe.define_singleton_method(:push) do |_write|
      File.open(lock_path) { |other| held << !other.flock(File::LOCK_EX | File::LOCK_NB) }
    end
    AtomicWrites.log = probe
    yield
    held
  ensure
    AtomicWrites.log = nil
  end
end

# The shipped channel kinds, with Telegram's Bot API answered by a fixture client.
module ChannelKindsFixture
  module_function

  def telegram(client_factory)
    telegram = Tamoz::Agent::CHANNEL_KINDS.fetch('telegram').with(options: { client_factory: })
    Tamoz::Agent::CHANNEL_KINDS.merge('telegram' => telegram)
  end
end

class Minitest::Test
  include ArtifactHelpers
  include AtomicWrites
end
