# frozen_string_literal: true

require_relative 'test_helper'

class TalkBoundaryTest < Minitest::Test
  TALK = ROOT.join('gems/tamoz-talk/lib')

  def test_the_talk_gem_needs_only_core_comms_and_the_standard_library
    requires = Dir[TALK.join('**/*.rb')].flat_map do |path|
      File.read(path, encoding: 'UTF-8').scan(/^\s*require\s+['"]([^'"]+)['"]/).flatten
    end

    assert_empty requires.uniq.grep(%r{\Atamoz/}) - %w[tamoz/core tamoz/comms]
    relative = Dir[TALK.join('**/*.rb')].flat_map do |path|
      File.read(path, encoding: 'UTF-8').scan(/require_relative\s+['"]([^'"]+)['"]/).flatten
    end

    assert(relative.none? { |target| target.include?('..') }, 'no require_relative reaches into another gem')
    refute(Dir[TALK.join('**/*.rb')].any? do |path|
      File.read(path, encoding: 'UTF-8').match?(/Tamoz::(SQLite|Agent)\b/)
    end)
  end

  def test_speech_synthesis_has_one_caller_the_injected_synthesizer
    callers = Dir[ROOT.join('gems/*/lib/**/*.rb')].select do |path|
      File.read(path, encoding: 'UTF-8').match?(/\.speak\(/)
    end

    assert_equal(['gems/tamoz-agent-cli/lib/tamoz/agent/cli_talk_commands.rb'],
                 callers.map { |path| Pathname(path).relative_path_from(ROOT).to_s })
  end
end
