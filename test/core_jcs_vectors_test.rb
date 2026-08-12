# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Executable agreement with the Go side (CONTRACTS.md §12): both products read
# the same vendored vectors file and must reproduce every value. The digests in
# the file ARE the cross-language agreement — a Ruby digest that differs from
# the file's digest differs from Go's.
class CoreJcsVectorsTest < Minitest::Test
  VECTORS_PATH = ROOT.join("gems/tamoz-stream/contracts/canonicalization-vectors.json")

  def setup
    @vectors = JSON.parse(File.read(VECTORS_PATH, encoding: Encoding::UTF_8))
  end

  def test_accept_vectors_reproduce_canonical_and_digest
    @vectors.fetch("accept").each do |vector|
      input = vector.fetch("input")
      canonical = Tamoz::Core.jcs(input)
      assert_equal vector.fetch("canonical"), canonical,
                   "canonical mismatch for #{vector.fetch("name")}"
      assert_equal vector.fetch("digest"), Tamoz::Core.digest(vector.fetch("domain"), input),
                   "digest mismatch for #{vector.fetch("name")}"
    end
  end

  def test_native_only_double_integral_cases
    # JSON cannot distinguish the double 1.0 from the integer 1, so these MUST
    # be constructed natively. A harness that skips them has a hole exactly
    # where Ruby diverges (ruby-json emits 1.0).
    assert_equal '{"n":1}', Tamoz::Core.jcs({ "n" => 1.0 })
    assert_equal '{"n":-2}', Tamoz::Core.jcs({ "n" => -2.0 })
    assert_equal '{"n":1}', Tamoz::Core.jcs({ "n" => 1 })
    assert_equal '{"n":-2}', Tamoz::Core.jcs({ "n" => -2 })
  end

  def test_native_only_digest_matches_the_domain_rule
    # Pinned by construction from the rule; identical to what Go's harness
    # computes over the same native case (sha256 of "situation-runtime/test/v1\n"
    # + '{"n":1}').
    assert_equal(
      "sha256:6ba2638cfdfbe38d023ebd9658b9851bc1600a161ebe4cfeedb28bcc38b79ec5",
      Tamoz::Core.digest("situation-runtime/test/v1\n", { "n" => 1.0 })
    )
  end

  def test_reject_vectors_are_refused
    @vectors.fetch("reject").each do |vector|
      name = vector.fetch("name")
      if vector.fetch("input_form") == "raw_json"
        assert_raises(Tamoz::Core::JCS::Error, "#{name} must be refused") do
          Tamoz::Core.jcs_json(vector.fetch("input"))
        end
      else
        assert_raises(Tamoz::Core::JCS::Error, "#{name} must be refused") do
          Tamoz::Core.jcs(native_value_for(name))
        end
      end
    end
  end

  def test_constant_time_verify_rejects_mismatch
    document = { "a" => [1, 2, 3] }
    good = Tamoz::Core.digest("situation-runtime/test/v1\n", document)
    assert Tamoz::Core.verify_digest("situation-runtime/test/v1\n", document, good)
    refute Tamoz::Core.verify_digest("situation-runtime/test/v1\n", { "a" => [1, 2, 4] }, good)
    refute Tamoz::Core.verify_digest("situation-runtime/test/v1\n", document, "sha256:#{"0" * 64}")
    refute Tamoz::Core.verify_digest("situation-runtime/test/v1\n", document, "md5:deadbeef")
    refute Tamoz::Core.verify_digest("situation-runtime/test/v1\n", document, nil)
  end

  def test_raw_json_and_ruby_value_agree
    raw = '{"z":[3,1,2],"a":{"n":null,"t":true}}'
    value = JSON.parse(raw)
    assert_equal Tamoz::Core.jcs(value), Tamoz::Core.jcs_json(raw)
  end

  def test_received_snapshot_digest_verifies
    vector = @vectors.fetch("accept").find { |entry| entry.fetch("name") == "snapshot-v1" }
    input = vector.fetch("input")
    assert Tamoz::Core.verify_digest(:snapshot, input, vector.fetch("digest"))
  end

  # Integers beyond 2**53 that survive a double round-trip serialize with ES
  # shortest-round-trip semantics (Go agrees with ES). The exact decimal and
  # the ES form differ: 2**60 -> "1152921504606847000", never the 19-digit
  # exact value. Also covers the exponent threshold: 1e21 as an INTEGER form
  # is exponential, matching the float form.
  def test_above_safe_integer_uses_es_shortest_round_trip
    assert_equal '{"n":1152921504606847000}', Tamoz::Core.jcs({ "n" => 1_152_921_504_606_846_976 })
    assert_equal '{"n":1e+21}', Tamoz::Core.jcs({ "n" => 1_000_000_000_000_000_000_000 })
    assert_equal '{"n":1152921504606847000}', Tamoz::Core.jcs_json('{"n":1152921504606846976}')
    assert_equal '{"n":1e+21}', Tamoz::Core.jcs_json('{"n":1000000000000000000000}')
    # The float form agrees byte-for-byte with the integer form.
    assert_equal Tamoz::Core.jcs({ "n" => 1_152_921_504_606_846_976 }),
                 Tamoz::Core.jcs({ "n" => 1_152_921_504_606_846_976.0 })
  end

  # Mixed-type Hash keys collapse to one string key after coercion; a digest
  # over such a value would be over invalid JSON and could never agree with
  # the Go side. Fail closed instead of sealing a duplicate key.
  def test_duplicate_keys_after_stringification_are_refused
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs({ 1 => "x", "1" => "y" }) }
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs({ "a" => 1, a: 2 }) }
  end

  # RFC 8259 requires control characters to be escaped; Go refuses raw control
  # bytes in strings. Ruby must refuse the same documents.
  def test_raw_control_characters_in_strings_are_refused
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs_json("{\"k\":\"a\x01b\"}") }
  end

  def test_nesting_depth_is_bounded
    deep = "[" * 600 + "]" * 600
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs_json(deep) }
    shallow = "[" * 100 + "]" * 100
    assert_equal 200, Tamoz::Core.jcs_json(shallow).length
  end

  # Scanner regression: the sign-consumption advance must not skip the first
  # mantissa digit. The only negative accept vector (-17.2, two-digit integer
  # part) parsed "by luck", so single-digit integer parts were never covered.
  def test_scanner_accepts_negative_numbers_with_single_digit_integer_part
    assert_equal '{"n":-1}', Tamoz::Core.jcs_json('{"n":-1}')
    assert_equal '{"n":-0.5}', Tamoz::Core.jcs_json('{"n":-0.5}')
    assert_equal '{"n":-3.7}', Tamoz::Core.jcs_json('{"n":-3.7}')
    assert_equal '{"n":-5e-324}', Tamoz::Core.jcs_json('{"n":-5e-324}')
    assert_equal '{"n":-100000}', Tamoz::Core.jcs_json('{"n":-1e5}')
    assert_equal '{"n":-0.0015}', Tamoz::Core.jcs_json('{"n":-1.5e-3}')
    # The scanner and the Ruby-value path agree on every negative form.
    assert_equal Tamoz::Core.jcs({ "n" => -0.5 }), Tamoz::Core.jcs_json('{"n":-0.5}')
    assert_equal Tamoz::Core.jcs({ "n" => -5e-324 }), Tamoz::Core.jcs_json('{"n":-5e-324}')
  end

  # A bare '-' or a sign without digits is not a JSON number.
  def test_scanner_rejects_sign_without_digits
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs_json('{"n":-}') }
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs_json('{"n":-x}') }
  end

  # Invalid UTF-8 on the receive path surfaces as a typed refusal, not an
  # untyped encoding exception.
  def test_invalid_encoding_is_a_typed_refusal
    raw = "{\"k\":\"\xFF\"}".b
    assert_raises(Tamoz::Core::JCS::Error) { Tamoz::Core.jcs_json(raw) }
  end

  private

  def native_value_for(name)
    case name
    when "reject-nan" then Float::NAN
    when "reject-positive-infinity" then Float::INFINITY
    when "reject-negative-infinity" then -Float::INFINITY
    when "reject-negative-zero" then -0.0
    else
      raise "no native constructor for #{name}"
    end
  end
end
