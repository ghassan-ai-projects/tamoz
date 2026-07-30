# frozen_string_literal: true

require_relative "test_helper"

class CanonicalJSONTest < Minitest::Test
  def test_key_order_does_not_change_digest
    first = {"b" => 2, "a" => {"z" => true, "x" => nil}}
    second = {"a" => {"x" => nil, "z" => true}, "b" => 2}

    assert_equal(
      Tamoz::Evals::CanonicalJSON.content_digest(first, domain: "test"),
      Tamoz::Evals::CanonicalJSON.content_digest(second, domain: "test")
    )
  end

  def test_domain_separation_changes_digest
    document = {"value" => 1}

    refute_equal(
      Tamoz::Evals::CanonicalJSON.content_digest(document, domain: "case"),
      Tamoz::Evals::CanonicalJSON.content_digest(document, domain: "result")
    )
  end

  def test_floating_point_values_are_rejected
    error = assert_raises(Tamoz::Evals::InvalidArtifactError) do
      Tamoz::Evals::CanonicalJSON.dump({"cost" => 0.1})
    end

    assert_includes error.message, "scaled integers"
  end

  def test_unicode_keys_cannot_collide_after_normalization
    composed = "\u00E9"
    decomposed = "e\u0301"

    assert_raises(Tamoz::Evals::InvalidArtifactError) do
      Tamoz::Evals::CanonicalJSON.dump(composed => 1, decomposed => 2)
    end
  end

  def test_non_ascii_strings_are_normalized_without_corrupting_utf8
    composed = "Tamoz café"
    decomposed = "Tamoz cafe\u0301"

    assert_equal(
      Tamoz::Evals::CanonicalJSON.dump("title" => composed),
      Tamoz::Evals::CanonicalJSON.dump("title" => decomposed)
    )
  end
end
