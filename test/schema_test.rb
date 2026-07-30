# frozen_string_literal: true

require_relative "test_helper"

class SchemaTest < Minitest::Test
  def test_any_of_accepts_more_than_one_matching_branch
    schema = Tamoz::Evals::Schema.new(
      "anyOf" => [
        {"type" => "integer"},
        {"type" => "number"}
      ]
    )

    assert schema.validate!(1)
  end

  def test_unsupported_schema_keywords_fail_closed
    error = assert_raises(Tamoz::Evals::SchemaError) do
      Tamoz::Evals::Schema.new("type" => "string", "format" => "date-time")
    end

    assert_includes error.message, "unsupported schema keywords"
  end

  def test_packaged_schemas_use_only_supported_keywords
    %w[case result].each do |artifact_type|
      assert Tamoz::Evals::Schema.load(artifact_type)
    end
  end
end
