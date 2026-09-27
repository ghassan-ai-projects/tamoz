# frozen_string_literal: true

require 'digest'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'tamoz/agent'
require_relative 'episode_composition'
require_relative 'local_model_endpoint'
require_relative 'aquaculture_domain'
require_relative 'investigation_grader'

# Measurement plan 16: runs the investigation corpus through the real episode graph, the real probe layer and the
# fixture MCP server, and grades each run. The model is whatever the composition is given: a scripted control
# (plumbing, never evidence of reasoning) or a real provider (script/investigation_real_run).
module InvestigationEval
  ROOT = File.expand_path('../..', __dir__)
  CORPUS_PATH = File.join(ROOT, 'test/fixtures/investigation/aquaculture.json')
  SERVER = File.join(ROOT, 'script/investigation_fixture_server')
  ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB BUNDLE_GEMFILE RUBYOPT].freeze

  # The fixture server behind the probe, and the count of reads it has served.
  Fixture = Data.define(:source, :calls_path) do
    def server_calls = File.exist?(calls_path) ? File.readlines(calls_path).length : 0
  end

  module_function

  def corpus = @corpus ||= check_codes(JSON.parse(File.read(CORPUS_PATH)))
  def cells = corpus.fetch('cells')
  def corpus_digest = "sha256:#{Digest::SHA256.file(CORPUS_PATH).hexdigest}"

  # Opaque, so neither the snapshot nor the pinned selector names the cell.
  def pond_id(cell, seed) = "pond-#{Digest::SHA256.hexdigest("#{cell.fetch('id')}~#{seed}")[0, 8]}"

  def check_codes(data)
    codes = AquacultureDomain::CATALOG.map { |entry| entry.fetch('code') }
    used = data.fetch('abstain_codes') + data.fetch('symptom_codes') + data.fetch('intent_causes').values +
           data.fetch('cells').map { |cell| cell.fetch('truth') } + [data.dig('controls', 'guess_code')]
    unknown = used.uniq - codes
    raise ArgumentError, "investigation corpus names codes outside the catalog: #{unknown.join(', ')}" unless
      unknown.empty?

    data
  end

  def with_fixture(seeds:)
    raise ArgumentError, 'the fixture server knows seeds 0..99' unless seeds.all? { |seed| seed.between?(0, 99) }

    Dir.mktmpdir('tamoz-inv') do |directory|
      calls_path = File.join(directory, 'calls.log')
      source = Tamoz::Agent::McpSourceBuilder.new(runtime_directory(directory, calls_path, seeds)).build
      begin
        yield Fixture.new(source:, calls_path:)
      ensure
        source.close
      end
    end
  end

  def runtime_directory(directory, calls_path, seeds)
    runtime = File.join(directory, 'runtime')
    FileUtils.mkdir_p(runtime, mode: 0o700)
    File.chmod(0o700, runtime)
    path = File.join(runtime, 'config.yaml')
    File.write(path, Psych.dump(runtime_config(directory, calls_path, seeds)))
    File.chmod(0o600, path)
    Tamoz::Agent::RuntimeDirectory.resolve(path: runtime, env: {})
  end

  def runtime_config(directory, calls_path, seeds)
    server = { 'id' => 'ponds', 'command' => RbConfig.ruby, 'arguments' => [SERVER, CORPUS_PATH, calls_path],
               'env_allowlist' => ENV_ALLOWLIST, 'read_only_tools' => ['query'] }
    probe = corpus.fetch('probe').merge('backing' => { 'server' => 'ponds', 'tool' => 'query' })
    targets = cells.product(seeds.to_a).to_h { |cell, seed| [pond_id(cell, seed), { 'stream' => pond_id(cell, seed) }] }
    { 'runtime' => { 'schema_version' => 1 }, 'workspace' => { 'root' => directory },
      'sources' => { 'mcp' => { 'enabled' => true, 'servers' => [server] },
                     'probes' => { 'enabled' => true, 'targets' => targets, 'probes' => [probe] } } }
  end

  def wire(cell, seed, episode_id)
    snapshot = AquacultureDomain.snapshot(pond_id: pond_id(cell, seed))
    snapshot = snapshot.merge('facts' => corpus.fetch('facts').merge('pond_id' => pond_id(cell, seed)))
    request = EpisodeComposition.wire_request(episode_id:, snapshot:, prompt: corpus.fetch('prompt'),
                                              allowed_intent_types: corpus.fetch('allowed_intent_types'))
    EpisodeComposition.grant_tools(request, [{ 'name' => corpus.dig('probe', 'name') }])
    request.budget = Agenticstream::Runtime::V1::EpisodeBudget.new(max_tool_calls: 3, max_model_calls: 4)
    request
  end

  # Runs one cell under one seed through a composition, grades it, and removes the composition's files.
  def run_cell(cell, seed, composition, episode_id)
    request = wire(cell, seed, episode_id)
    events = composition.fetch(:runner).run(request).to_a
    InvestigationGrader::Cell.new(corpus, cell, seed, events.filter_map(&:terminal).last,
                                  terminal_state(composition, request)).result
  ensure
    composition.fetch(:adapter).close
    FileUtils.remove_entry(composition.fetch(:directory))
  end

  def terminal_state(composition, request)
    app = composition.fetch(:app)
    thread = "episode.#{request.episode_id}"
    result = app.durable_runner.fetch(thread:, namespace: [request.tenant_id],
                                      request_id: "#{thread}.#{request.attempt_id}.#{request.fence}")
    return {} unless result&.checkpoint_id

    app.state(thread:, namespace: [request.tenant_id], checkpoint_id: result.checkpoint_id).state.to_h
  end
end
