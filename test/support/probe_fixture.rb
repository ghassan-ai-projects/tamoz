# frozen_string_literal: true

require 'tamoz/agent'
require 'tamoz/mcp'

# A governed probe over an in-process stand-in for an operator MCP server. Plumbing only: the stand-in replays
# scripted text; nothing here is a model or evidence that one reasons.
module ProbeFixture
  Invocation = Tamoz::Mcp::Invocation

  # The inner MCP source: one read-only `logs/query` tool whose answers are scripted per call.
  class FakeMcpSource
    attr_reader :calls, :descriptors

    # answers: one entry per call (a String, or an exception class to raise); the last repeats.
    def initialize(answers)
      @answers = answers
      @calls = []
      @descriptors = [Invocation::Descriptor.new(id: 'mcp:logs/query', name: 'query', source_id: 'logs',
                                                 definition_digest: 'sha256:fixture', input_schema: {},
                                                 output_schema: nil, effect_class: :read_only,
                                                 protocol_profile: 'fixture')]
    end

    def name?(name) = name == 'mcp:logs/query'
    def catalogs = {}
    def mcp_catalogs = {}
    def empty? = false
    def close = nil
    def read_only?(name) = name?(name)
    def mcp_source_digests = { 'logs' => 'sha256:fixture' }

    def execute(_context, name, arguments)
      @calls << [name, arguments]
      answer = @answers[@calls.length - 1] || @answers.last
      raise answer, 'scripted failure' if answer.is_a?(Class)

      observation = Invocation::Observation.new(server_id: 'logs', content_blocks: [], text: answer,
                                                structured_content: nil, truncated: false)
      Invocation::Outcome.new(status: :succeeded, observation:, interrupt: nil, denial: nil, effect_key: 'fixture')
    end
  end

  SETTINGS = {
    'targets' => { 'pond-07' => { 'stream' => 'pond=07' } },
    'probes' => [{ 'name' => 'probe_pond_log', 'description' => 'Search the pond controller log.',
                   'backing' => { 'server' => 'logs', 'tool' => 'query' },
                   'arguments' => { 'selector' => '{target.stream}', 'from' => '{window.from}',
                                    'until' => '{window.until}',
                                    'filter' => { 'free' => 'string', 'max_bytes' => 64 } } }]
  }.freeze

  module_function

  def source(answers, settings: SETTINGS)
    inner = FakeMcpSource.new(answers)
    catalog = Tamoz::Agent::ProbeCatalog.new(settings, servers: { 'logs' => { 'read_only_tools' => ['query'] } })
    [Tamoz::Agent::ProbeSource.new(source: inner, catalog:), inner]
  end
end
