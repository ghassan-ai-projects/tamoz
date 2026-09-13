# frozen_string_literal: true

require_relative "test_helper"

class CoreStateCodecTest < Minitest::Test
  Point = Data.define(:x, :y)

  def test_built_in_round_trip_is_deterministic_and_immutable
    codec = Tamoz::StateCodec.new
    first = {
      :symbol_key => [nil, true, false, 12, -0.25, "café"],
      "alpha" => {"z" => 1, "a" => 2}
    }
    second = {
      "alpha" => {"a" => 2, "z" => 1},
      "symbol_key" => [nil, true, false, 12, -0.25, "café"]
    }

    assert_equal codec.dump(first), codec.dump(second)
    decoded = codec.load(codec.dump(first))
    assert_equal second, decoded
    assert decoded.frozen?
    assert decoded.fetch("symbol_key").frozen?
    assert decoded.fetch("alpha").keys.all?(&:frozen?)
    assert_raises(FrozenError) { decoded["new"] = true }
  end

  def test_registered_value_round_trip_and_legacy_decoder
    codec = Tamoz::StateCodec.new
                            .add_registration(
                              tag: "test.point",
                              version: 1,
                              klass: Point,
                              encoder: ->(point) { {"x" => point.x, "y" => point.y} },
                              decoder: ->(payload) { Point.new(payload.fetch("x"), payload.fetch("y")) },
                              immutability: ->(point) { point.frozen? },
                              encode: false
                            )
                            .add_registration(
                              tag: "test.point",
                              version: 2,
                              klass: Point,
                              encoder: ->(point) { [point.x, point.y] },
                              decoder: ->(payload) { Point.new(*payload) },
                              immutability: ->(point) { point.frozen? }
                            )

    point = Point.new(3, 5)
    assert_equal point, codec.load(codec.dump(point))

    legacy = JSON.generate(
      [
        "tamoz.state",
        1,
        ["registered", "test.point", 1, ["object", [["x", ["integer", 8]], ["y", ["integer", 13]]]]]
      ]
    )
    assert_equal Point.new(8, 13), codec.load(legacy)
  end

  def test_unknown_registration_is_rejected_before_any_decoder_runs
    calls = 0
    codec = Tamoz::StateCodec.new.add_registration(
      tag: "test.point",
      version: 1,
      klass: Point,
      encoder: ->(point) { [point.x, point.y] },
      decoder: lambda do |payload|
        calls += 1
        Point.new(*payload)
      end,
      immutability: ->(point) { point.frozen? }
    )
    wire = JSON.generate(
      [
        "tamoz.state",
        1,
        [
          "array",
          [
            ["registered", "test.point", 1, ["array", [["integer", 1], ["integer", 2]]]],
            ["registered", "unknown.value", 9, ["nil"]]
          ]
        ]
      ]
    )

    assert_raises(Tamoz::CheckpointVersionError) { codec.load(wire) }
    assert_equal 0, calls
  end

  def test_registered_decoder_must_return_exact_immutable_class
    mutable_class = Class.new do
      def initialize(value)
        @value = value
      end
    end
    codec = Tamoz::StateCodec.new.add_registration(
      tag: "test.mutable",
      version: 1,
      klass: mutable_class,
      encoder: ->(_value) { nil },
      decoder: ->(_payload) { mutable_class.new(1) },
      immutability: ->(value) { value.frozen? }
    )
    wire = JSON.generate(["tamoz.state", 1, ["registered", "test.mutable", 1, ["nil"]]])

    error = assert_raises(Tamoz::CheckpointCorruptionError) { codec.load(wire) }
    assert_includes error.message, "mutable"
  end

  def test_registration_requires_and_enforces_an_explicit_immutability_contract
    mutable_class = Class.new do
      attr_reader :values

      def initialize(values)
        @values = values
        freeze
      end
    end
    attributes = {
      tag: "test.explicit",
      version: 1,
      klass: mutable_class,
      encoder: ->(value) { value.values },
      decoder: ->(payload) { mutable_class.new(payload) }
    }

    assert_raises(ArgumentError) { Tamoz::StateCodec.new.add_registration(**attributes) }

    codec = Tamoz::StateCodec.new.add_registration(
      **attributes,
      immutability: ->(value) { value.frozen? && value.values.frozen? }
    )
    shallowly_frozen = mutable_class.new([1])
    assert_raises(Tamoz::InvalidUpdateError) { codec.dump(shallowly_frozen) }
  end

  def test_registration_cannot_override_core_or_secret_types
    base = {
      tag: "test.reserved",
      version: 1,
      encoder: ->(value) { value },
      decoder: ->(payload) { payload },
      immutability: ->(value) { value.frozen? }
    }

    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::StateCodec.new.add_registration(**base, klass: String)
    end
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::StateCodec.new.add_registration(**base, klass: Tamoz::Secret)
    end
  end

  def test_sensitive_unsupported_cyclic_and_ambiguous_values_fail_closed
    codec = Tamoz::StateCodec.new
    cyclic = []
    cyclic << cyclic

    assert_raises(Tamoz::SensitiveValueError) { codec.dump("secret" => Tamoz::Secret.new("token")) }
    assert_raises(Tamoz::UnsupportedValueError) { codec.dump(Object.new) }
    assert_raises(Tamoz::UnsupportedValueError) { codec.dump(Float::INFINITY) }
    assert_raises(Tamoz::UnsupportedValueError) { codec.dump(:symbol_value) }
    assert_raises(Tamoz::UnsupportedValueError) { codec.dump(cyclic) }
    assert_raises(Tamoz::UnsupportedValueError) { codec.dump("same" => 1, same: 2) }
  end

  def test_limits_apply_on_dump_and_load
    codec = Tamoz::StateCodec.new(
      max_bytes: 128,
      max_depth: 2,
      max_collection_items: 3,
      max_string_bytes: 8
    )

    assert_raises(Tamoz::StateLimitError) { codec.dump("123456789") }
    assert_raises(Tamoz::StateLimitError) { codec.dump([1, 2, 3, 4]) }
    assert_raises(Tamoz::StateLimitError) { codec.dump([[[[1]]]]) }
    assert_raises(Tamoz::CheckpointCorruptionError) do
      codec.load(JSON.generate(["tamoz.state", 1, ["string", "123456789"]]))
    end
  end

  def test_limit_configuration_has_hard_ceilings
    assert_raises(Tamoz::ConfigurationError) { Tamoz::StateCodec.new(max_depth: 257) }
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::StateCodec.new(max_bytes: (64 * 1024 * 1024) + 1)
    end
  end

  def test_deterministic_round_trip_property
    50.times do |seed|
      random = Random.new(seed)
      pairs = 12.times.map { |index| ["key-#{index}", random.rand(-10_000..10_000)] }
      first = pairs.shuffle(random: random).to_h
      second = pairs.reverse.to_h
      codec = Tamoz::StateCodec.new

      assert_equal codec.dump(first), codec.dump(second), "seed=#{seed}"
      assert_equal second.sort.to_h, codec.load(codec.dump(first)), "seed=#{seed}"
    end
  end

  def test_malformed_wire_corpus_is_rejected
    codec = Tamoz::StateCodec.new
    invalid = [
      "{}",
      JSON.generate(["tamoz.state", 2, ["nil"]]),
      JSON.generate(["tamoz.state", 1, ["nil", "extra"]]),
      JSON.generate(["tamoz.state", 1, ["float", 1]]),
      JSON.generate(["tamoz.state", 1, ["object", [["b", ["nil"]], ["a", ["nil"]]]]]),
      JSON.generate(["tamoz.state", 1, ["object", [["a", ["nil"]], ["a", ["nil"]]]]]),
      JSON.generate(["tamoz.state", 1, ["unknown"]])
    ]

    invalid.each do |wire|
      assert_raises(Tamoz::CheckpointError, wire) { codec.load(wire) }
    end
  end

  def test_secret_redacts_ordinary_string_conversion
    secret = Tamoz::Secret.new("super-secret")

    assert_equal "super-secret", secret.reveal
    refute_includes secret.inspect, "super-secret"
    refute_includes secret.to_s, "super-secret"
    assert secret.frozen?
  end

  def test_error_metadata_is_stable_and_inspection_is_safe
    error = Tamoz::StoreError.new("database password leaked in raw error")

    assert_equal "store", error.category
    assert error.retryable?
    refute error.user_visible?
    refute_includes error.inspect, "password"
    assert_equal "The runtime store is unavailable.", error.safe_message
    assert_raises(ArgumentError) do
      Tamoz::StoreError.new("raw", category: "forged")
    end
  end
end
