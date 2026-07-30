# frozen_string_literal: true

require_relative "test_helper"

class DuplicateKeyDetectorTest < Minitest::Test
  VALID_CORPUS = [
    "null",
    "true",
    "false",
    "0",
    "-12",
    "1e2",
    '"Tamoz café"',
    '"\uD834\uDD1E"',
    "[]",
    "{}",
    %q({"nested":[1,{"safe":"value"}],"escaped":"a\\b\"c"}),
    " \n\t{\"a\":1}\r "
  ].freeze
  INVALID_CORPUS = [
    "",
    "01",
    "NaN",
    "[1,]",
    '{"a":}',
    '{"a":1} trailing',
    '"unterminated',
    %q("\uZZZZ"),
    "[",
    "{"
  ].freeze

  def test_detector_agrees_with_json_parser_on_non_duplicate_corpus
    VALID_CORPUS.each do |text|
      JSON.parse(text, create_additions: false)
      assert Tamoz::Evals::DuplicateKeyDetector.validate!(text)
    end

    INVALID_CORPUS.each do |text|
      assert_raises(JSON::ParserError, text) { JSON.parse(text, create_additions: false) }
      assert_raises(Tamoz::Evals::InvalidArtifactError, text) do
        Tamoz::Evals::DuplicateKeyDetector.validate!(text)
      end
    end
  end

  def test_excessive_nesting_fails_without_consuming_the_process_stack
    text = ("[" * 102) + "0" + ("]" * 102)

    error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
      Tamoz::Evals::DuplicateKeyDetector.validate!(text)
    end
    assert_includes error.message, "nesting exceeds"
  end
end
