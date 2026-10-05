# frozen_string_literal: true

module DeepFreezeAssertions
  private

  def assert_deeply_frozen(value)
    assert_predicate value, :frozen?
    case value
    when Hash
      value.each do |key, entry|
        assert_deeply_frozen(key)
        assert_deeply_frozen(entry)
      end
    when Array

      value.each { |entry| assert_deeply_frozen(entry) }
    end
  end
end
