# frozen_string_literal: true

require_relative 'test_helper'

# The CLI fixture assembles a complete mission catalog manifest before spawning
# the script entry point.
# rubocop:disable Metrics/MethodLength
class OpenclawBenchmarkReadinessCLITest < Minitest::Test
  SCRIPT = ROOT.join('script', 'benchmark_openclaw_readiness')
  MISSIONS = ROOT.join('documentation', 'benchmark', 'OPENCLAW_MISSIONS.json')

  def protocol_path(directory)
    path = directory.join('protocol.json')
    File.write(path, JSON.generate({ 'benchmark_protocol_version' => 'openclaw.v1' }))
    path
  end

  def manifest_path(directory, run_kind: 'fixture')
    protocol = { 'benchmark_protocol_version' => 'openclaw.v1' }
    path = directory.join('manifest.json')
    capabilities = {
      'exists' => true, 'reachable' => true, 'authorized' => true,
      'attempted' => true, 'effective' => true, 'completed' => true,
      'verified' => true
    }
    manifest = {
      'protocol_sha256' => Tamoz::Evals::Benchmark::Readiness.protocol_digest(protocol),
      'run_kind' => run_kind, 'provider' => 'provider', 'model' => 'model',
      'artifact_root' => run_kind == 'fixture' ? 'fixtures/test' : 'real-provider/test',
      'git_revision' => "sha256:#{'c' * 64}",
      'config_sha256' => "sha256:#{'d' * 64}",
      'graph' => { 'name' => 'tamoz.agent.session', 'version' => '2' },
      'surfaces' => %w[cli telegram],
      'command' => 'script/benchmark_openclaw_readiness',
      'controls_passed' => true, 'capabilities' => { 'read_only' => capabilities },
      'missions' => JSON.parse(File.read(MISSIONS)).fetch('missions').map do |mission|
        {
          'id' => mission.fetch('id'), 'status' => 'ready',
          'artifact_path' => "#{mission.fetch('id')}.json",
          'artifact_digest' => "sha256:#{'b' * 64}"
        }
      end
    }
    File.write(path, JSON.generate(manifest))
    path
  end

  def test_publish_refuses_fixture_manifest
    Dir.mktmpdir('openclaw-readiness') do |directory|
      root = Pathname.new(directory)
      command = [RbConfig.ruby, SCRIPT.to_s, '--protocol', protocol_path(root).to_s,
                 '--manifest', manifest_path(root).to_s, '--missions', MISSIONS.to_s, '--publish']
      _stdout, stderr, status = Open3.capture3(*command, chdir: ROOT.to_s)

      refute_predicate status, :success?
      assert_includes stderr, 'fixture_or_fake_provider'
    end
  end
end
# rubocop:enable Metrics/MethodLength
