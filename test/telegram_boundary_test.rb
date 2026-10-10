# frozen_string_literal: true

require_relative 'test_helper'

class TelegramBoundaryTest < Minitest::Test
  TELEGRAM = ROOT.join('gems/tamoz-telegram/lib')

  def test_the_telegram_gem_needs_only_comms_and_the_standard_library
    sources = Dir[TELEGRAM.join('**/*.rb')].map { |path| File.read(path, encoding: 'UTF-8') }
    requires = sources.flat_map { |source| source.scan(/^\s*require\s+['"]([^'"]+)['"]/).flatten }

    assert_empty requires.uniq.grep(%r{\Atamoz/}) - %w[tamoz/core tamoz/comms]
    assert(sources.flat_map { |source| source.scan(/require_relative\s+['"]([^'"]+)['"]/).flatten }
                  .none? { |target| target.include?('..') }, 'no require_relative reaches into another gem')
    refute(sources.any? { |source| source.match?(/Tamoz::(SQLite|Agent)\b/) })
  end
end
