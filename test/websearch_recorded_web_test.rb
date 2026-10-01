# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/research_spec'

# The eval's Brave cap and query cache (docs/deep-research-2026-09-30/EVAL.md §3): offline, no socket.
# rubocop:disable Minitest/MultipleAssertions -- each case reads one record behaviour from several sides.
class WebsearchRecordedWebTest < Minitest::Test
  include ResearchSpec

  W = Tamoz::Mcp::Websearch

  def test_the_ledger_refuses_the_search_past_its_cap
    Dir.mktmpdir do |dir|
      ledger = W::SearchLedger.new(counter(dir, used: 499))
      ledger.charge!

      assert_raises(W::SearchLedger::Exhausted) { ledger.charge! }
      assert_equal({ 'cap' => 500, 'used' => 500 }, JSON.parse(File.read(File.join(dir, 'ledger.json'))))
    end
  end

  def test_concurrent_charges_are_each_counted_and_land_through_atomic_file
    Dir.mktmpdir do |dir|
      path = counter(dir, used: 0)
      ledger = W::SearchLedger.new(path)
      writes = atomic_writes { Array.new(8) { Thread.new { ledger.charge! } }.each(&:join) }

      assert_equal 8, JSON.parse(File.read(path)).fetch('used')
      published = writes.map { |operation, written, _mode| [operation, written] }

      assert_equal [[:replace, path]] * 8, published
    end
  end

  def test_the_ledger_is_replaced_only_while_its_lock_is_held
    Dir.mktmpdir do |dir|
      path = counter(dir, used: 0)
      held = lock_held_during_atomic_writes("#{path}.lock") { W::SearchLedger.new(path).charge! }

      assert_equal [true], held
    end
  end

  def test_a_repeated_query_is_served_from_the_record_without_a_charge
    Dir.mktmpdir do |dir|
      web = W::RecordedWeb.new(dir: File.join(dir, 'cache'), ledger: W::SearchLedger.new(counter(dir, used: 0)))
      live = 0
      first = web.search('Oslo  Population', 5) do
        live += 1
        [{ 'url' => 'https://a.example/' }]
      end
      again = web.search('oslo population', 5) do
        live += 1
        []
      end

      assert_equal first, again
      assert_equal 1, live
      assert_equal 1, JSON.parse(File.read(File.join(dir, 'ledger.json'))).fetch('used')
    end
  end

  def test_a_recorded_answer_lands_through_atomic_file
    Dir.mktmpdir do |dir|
      web = W::RecordedWeb.new(dir: File.join(dir, 'cache'))
      writes = atomic_writes { web.read('https://a.example/') { { 'text' => 'page' } } }

      recorded = Dir[File.join(dir, 'cache', 'page-*.json')].first

      assert_equal [[:replace, recorded, Tamoz::Core::AtomicFile::DEFAULT_MODE]], writes
    end
  end

  def test_the_adapter_refuses_a_live_search_once_the_cap_is_spent_but_serves_a_recorded_one
    Dir.mktmpdir do |dir|
      with_fixture_web do
        ENV['TAMOZ_WEBSEARCH_CACHE'] = File.join(dir, 'cache')
        ENV['TAMOZ_WEBSEARCH_LEDGER'] = counter(dir, used: 0, cap: 1)
        WebsearchAdapter.reset!
        served = WebsearchAdapter.search_response('Oslo population statistics', 5)
        refused = WebsearchAdapter.search_response('Oslo municipality growth', 5)
        repeat = WebsearchAdapter.search_response('Oslo population statistics', 5)

        refute_predicate served, :error?
        assert_predicate refused, :error?
        assert_includes refused.content.first.fetch(:text), 'search budget of 1 requests is spent'
        refute_predicate repeat, :error?
      ensure
        ENV.delete('TAMOZ_WEBSEARCH_CACHE')
        ENV.delete('TAMOZ_WEBSEARCH_LEDGER')
      end
    end
  end

  private

  def counter(dir, used:, cap: 500)
    path = File.join(dir, 'ledger.json')
    File.write(path, JSON.generate('cap' => cap, 'used' => used))
    path
  end
end
# rubocop:enable Minitest/MultipleAssertions
