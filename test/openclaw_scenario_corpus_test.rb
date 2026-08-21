# frozen_string_literal: true

require_relative 'test_helper'

# The corpus contract is deliberately asserted as a set of related invariants;
# splitting each invariant into a one-assertion helper would hide the contract.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
class OpenclawScenarioCorpusTest < Minitest::Test
  INDEX_PATH = ROOT.join('docs', 'openclaw-intelligence-study', 'benchmark-protocol', 'scenarios',
                         'SCENARIO_INDEX.json')
  SCENARIO_ROOT = INDEX_PATH.dirname
  CATALOG_PATH = ROOT.join('documentation', 'benchmark', 'OPENCLAW_MISSIONS.json')
  EXPECTED_IDS = ((1..11).map { |number| "T#{number}" } + (1..9).map { |number| "F#{number}" }).freeze
  REQUIRED_ENTRY_KEYS = %w[
    scenario_id path state status_reason tier classification mission_ids axes
    required_capabilities surfaces allowed_run_kinds seed_policy budget_ref
    oracle_id catalog_metrics catalog_hard_zeros artifact_root_template
    local_prerequisites external_prerequisites
  ].freeze
  ALLOWED_STATES = %w[READY EXTERNAL_BLOCKED UNAVAILABLE INCOMPLETE].freeze
  ALLOWED_TIERS = %w[T F].freeze
  ALLOWED_CLASSIFICATIONS = %w[canonical composite frontier].freeze
  ALLOWED_RUN_KINDS = %w[fixture real_provider].freeze
  ALLOWED_SURFACES = %w[cli telegram].freeze

  def index
    @index ||= read_json(INDEX_PATH)
  end

  def catalog
    @catalog ||= read_json(CATALOG_PATH)
  end

  def missions
    @missions ||= catalog.fetch('missions').to_h { |mission| [mission.fetch('id'), mission] }
  end

  def entries
    index.fetch('scenarios')
  end

  def test_index_has_the_declared_schema_and_exact_corpus
    assert_equal 'openclaw.scenario-index.v1', index.fetch('schema_version')
    assert_equal 'docs/openclaw-intelligence-study/benchmark-protocol/scenarios', index.fetch('scenario_directory')
    assert_equal 'documentation/benchmark/OPENCLAW_MISSIONS.json', index.fetch('catalog')
    assert_equal 'documentation/benchmark/BENCHMARK_PROTOCOL.json#/budgets', index.fetch('budget_ref')
    assert_equal 'paired_protocol_seed', index.fetch('seed_policy')
    assert_equal EXPECTED_IDS.sort, entries.map { |entry| entry.fetch('scenario_id') }.sort
    assert_equal EXPECTED_IDS.length, entries.length

    expected_paths = scenario_files.map { |path| path.relative_path_from(SCENARIO_ROOT).to_s }.sort

    assert_equal expected_paths, entries.map { |entry| entry.fetch('path') }.sort
    assert_equal EXPECTED_IDS.sort, expected_paths.map { |path| scenario_id_for(path) }.sort
  end

  def test_entries_are_unique_and_have_the_required_schema
    assert_equal entries.length, entries.map { |entry| entry.fetch('scenario_id') }.uniq.length
    assert_equal entries.length, entries.map { |entry| entry.fetch('path') }.uniq.length

    entries.each do |entry|
      assert REQUIRED_ENTRY_KEYS.all? { |key| entry.key?(key) },
             "#{entry.fetch('scenario_id', 'unknown')} is missing a required index field"
      assert_equal entry.fetch('scenario_id'), scenario_id_for(entry.fetch('path'))
      assert entry.fetch('status_reason').is_a?(String) && !entry.fetch('status_reason').strip.empty?
      assert_includes ALLOWED_STATES, entry.fetch('state')
      assert_includes ALLOWED_TIERS, entry.fetch('tier')
      assert_includes ALLOWED_CLASSIFICATIONS, entry.fetch('classification')
      assert_match(/\Aopenclaw\.scenario\.[tf]\d+\.v1\z/, entry.fetch('oracle_id'))
      assert_equal 'documentation/benchmark/BENCHMARK_PROTOCOL.json#/budgets', entry.fetch('budget_ref')
      assert_equal 'paired_protocol_seed', entry.fetch('seed_policy')

      assert_unique_nonempty_strings(entry, 'axes')
      assert_unique_nonempty_strings(entry, 'required_capabilities')
      assert_unique_nonempty_strings(entry, 'surfaces')
      assert_unique_nonempty_strings(entry, 'allowed_run_kinds')
      assert_unique_nonempty_strings(entry, 'mission_ids', allow_empty: true)
      assert_unique_nonempty_strings(entry, 'catalog_metrics', allow_empty: true)
      assert_unique_nonempty_strings(entry, 'catalog_hard_zeros', allow_empty: true)
      assert_prerequisites(entry, 'local_prerequisites')
      assert_prerequisites(entry, 'external_prerequisites')
      assert_safe_relative_path(entry.fetch('path'), extension: '.md')
      assert_safe_relative_path(entry.fetch('artifact_root_template'), extension: nil)
      assert_includes entry.fetch('artifact_root_template'), '<seed>'
      assert_equal ALLOWED_SURFACES.sort, entry.fetch('surfaces').sort
      assert(entry.fetch('allowed_run_kinds').all? { |kind| ALLOWED_RUN_KINDS.include?(kind) })
    end
  end

  def test_states_and_classifications_make_incomplete_and_unavailable_explicit
    entries.each do |entry|
      if entry.fetch('tier') == 'T'
        assert_equal 'INCOMPLETE', entry.fetch('state'), entry.fetch('scenario_id')
        assert_equal 'canonical', entry.fetch('classification') if entry.fetch('scenario_id').match?(/\AT[1-5]\z/)
        if entry.fetch('scenario_id').match?(/\AT(?:6|7|8|9|10|11)\z/)
          assert_equal 'composite',
                       entry.fetch('classification')
        end

        assert_includes entry.fetch('status_reason'), 'B0', entry.fetch('scenario_id')
        refute_empty entry.fetch('mission_ids'), entry.fetch('scenario_id')
      else
        assert_equal 'UNAVAILABLE', entry.fetch('state'), entry.fetch('scenario_id')
        assert_equal 'frontier', entry.fetch('classification'), entry.fetch('scenario_id')
        if entry.fetch('scenario_id') == 'F7'
          assert_equal ['self-inspection'], entry.fetch('mission_ids')
        else
          assert_empty entry.fetch('mission_ids'), entry.fetch('scenario_id')
        end
      end
    end
  end

  def test_canonical_mappings_resolve_catalog_capabilities_surfaces_metrics_and_hard_zeros
    entries.each do |entry|
      mission_records = entry.fetch('mission_ids').map do |mission_id|
        assert missions.key?(mission_id), "#{entry.fetch('scenario_id')} maps to unknown mission #{mission_id.inspect}"
        missions.fetch(mission_id)
      end
      next if mission_records.empty?

      expected_capabilities = ordered_union(mission_records, 'required_capabilities')
      expected_surfaces = ordered_union(mission_records, 'surfaces')
      expected_metrics = ordered_union(mission_records, 'metrics')
      expected_hard_zeros = ordered_union(mission_records, 'hard_zero')

      assert_equal expected_metrics, entry.fetch('catalog_metrics'), entry.fetch('scenario_id')
      assert_equal expected_hard_zeros, entry.fetch('catalog_hard_zeros'), entry.fetch('scenario_id')
      assert_equal expected_surfaces.sort, entry.fetch('surfaces').sort, entry.fetch('scenario_id')
      assert expected_capabilities.all? { |capability| entry.fetch('required_capabilities').include?(capability) },
             "#{entry.fetch('scenario_id')} omits a catalog capability"
    end
  end

  def test_unmapped_frontier_entries_do_not_invent_catalog_contracts
    entries.select { |entry| entry.fetch('tier') == 'F' && entry.fetch('scenario_id') != 'F7' }.each do |entry|
      assert_empty entry.fetch('mission_ids')
      assert_empty entry.fetch('catalog_metrics')
      assert_empty entry.fetch('catalog_hard_zeros')
    end
  end

  private

  def scenario_files
    (SCENARIO_ROOT.glob('T*.md') + SCENARIO_ROOT.join('frontier').glob('F*.md')).sort
  end

  def scenario_id_for(path)
    match = path.match(%r{(?:\A|/)\K[TF]\d+(?=-)})

    refute_nil match, "scenario path has no stable T/F id: #{path.inspect}"
    match[0]
  end

  def assert_unique_nonempty_strings(entry, key, allow_empty: false)
    value = entry.fetch(key)

    assert_kind_of Array, value, "#{entry.fetch('scenario_id')} #{key} must be an array"
    assert(value.all? do |item|
      item.is_a?(String) && !item.strip.empty?
    end, "#{entry.fetch('scenario_id')} #{key} has a blank/non-string value")
    assert_equal value.length, value.uniq.length, "#{entry.fetch('scenario_id')} #{key} contains duplicates"
    refute_empty value unless allow_empty
  end

  def assert_prerequisites(entry, key)
    assert_unique_nonempty_strings(entry, key)
    entry.fetch(key).each do |prerequisite|
      refute_match(%r{\A(?:/|[A-Za-z]:[\\/])}, prerequisite)
    end
  end

  def assert_safe_relative_path(path, extension:)
    assert_kind_of String, path
    refute_empty path
    refute path.start_with?('/', '~'), "unsafe absolute path: #{path.inspect}"
    refute_includes path, '\\'
    refute_includes path.split('/'), '..'
    assert_equal path, Pathname.new(path).cleanpath.to_s
    assert_equal extension, Pathname.new(path).extname if extension
  end

  def ordered_union(records, key)
    records.flat_map { |record| record.fetch(key) }.uniq
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Minitest/MultipleAssertions
