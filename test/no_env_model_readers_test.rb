# frozen_string_literal: true

require_relative 'test_helper'

# Models live in the runtime config; no code reads a model from the environment (ADR-059: no shim).
class NoEnvModelReadersTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CODE = %w[gems/*/lib/**/*.rb gems/*/exe/* bin/* script/* scripts/* agenteval/**/*.rb apps/**/*.rb
            test/support/**/*.rb Rakefile .github/**/*.yml].freeze
  READER = /TAMOZ_(PROVIDER|MODEL)(?![_A-Z])|TAMOZ_(TRANSCRIPTION|VISION|VOICE)_|TAMOZ_#\{/

  def readers
    paths = CODE.flat_map { |glob| Dir[File.join(ROOT, glob)] }.select { |path| File.file?(path) }
    matches = paths.select { |path| File.read(path, encoding: 'UTF-8').match?(READER) }
    matches.map { |path| path.delete_prefix("#{ROOT}/") }
  end

  def test_no_code_reads_a_model_from_the_environment
    assert_empty readers
  end
end
