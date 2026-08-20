# frozen_string_literal: true

require_relative "test_helper"
require "support/benchmark_families"

# The benchmark-family driver is data-driven: every domain JSON discovered by
# DomainLoader must build a family, including hyphenated identifiers such as
# `cold-chain` (audit D3 — the old const_get boundary rejected them).
class BenchmarkFamiliesTest < Minitest::Test
  def test_a_family_is_built_for_every_discovered_domain
    DomainLoader.domains.each do |domain_name|
      family_id = DomainLoader.load(domain_name).benchmark_family.fetch("family_id")
      assert BenchmarkFamilies::FAMILIES.key?(family_id),
             "no benchmark family built for domain #{domain_name.inspect} (family_id #{family_id.inspect})"
    end
  end

  def test_cold_chain_family_is_reachable_and_data_driven
    family = BenchmarkFamilies::FAMILIES.fetch("cold-chain-excursion")
    facts = family.fetch("facts").call(1, Random.new(7))
    assert_kind_of String, family.fetch("truth").call(facts)
    # The domain value is the loader instance the pilot run drives.
    domain = family.fetch("domain")
    assert_respond_to domain, :prompt
    assert_respond_to domain, :snapshot
  end
end
