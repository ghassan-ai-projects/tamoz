# frozen_string_literal: true

require_relative 'test_helper'

class TalkBoundaryTest < Minitest::Test
  TALK = ROOT.join('gems/tamoz-talk/lib')

  def talk_sources
    @talk_sources ||= Dir[TALK.join('**/*.rb')].map { |path| File.read(path, encoding: 'UTF-8') }
  end

  def scan_talk(pattern)
    talk_sources.flat_map { |source| source.scan(pattern).flatten }
  end

  def test_the_talk_gem_needs_only_core_comms_and_the_standard_library
    requires = scan_talk(/^\s*require\s+['"]([^'"]+)['"]/)

    assert_empty requires.uniq.grep(%r{\Atamoz/}) - %w[tamoz/core tamoz/comms]
    relative = scan_talk(/require_relative\s+['"]([^'"]+)['"]/)

    assert(relative.none? { |target| target.include?('..') }, 'no require_relative reaches into another gem')
    refute(talk_sources.any? { |source| source.match?(/Tamoz::(SQLite|Agent)\b/) })
  end

  def test_speech_is_synthesized_only_by_the_gateway_voice_and_the_start_probe
    callers = Dir[ROOT.join('gems/*/lib/**/*.rb')].select do |path|
      File.read(path, encoding: 'UTF-8').include?('.speak(')
    end

    assert_equal(%w[gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb
                    gems/tamoz-agent-cli/lib/tamoz/agent/cli_start_checks.rb],
                 callers.map { |path| Pathname(path).relative_path_from(ROOT).to_s }.sort)
  end
end
