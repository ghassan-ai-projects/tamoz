# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../script/quality/test_inventory'

class TestQualityInventoryTest < Minitest::Test
  def test_every_discovered_file_has_one_row_and_unreviewed_files_are_not_marked_fine
    rows = TestQualityInventory.entries({})
    paths = rows.map { |row| row.fetch('path') }

    assert_equal TestSuite.files, paths
    assert_equal(['needs review'], rows.map { |row| row.fetch('status') }.uniq)
  end

  def test_recorded_findings_and_verification_survive_generation
    path = TestSuite.files.first
    review = { 'status' => 'needs improvement', 'reason' => 'Missing refusal assertion.',
               'verification' => 'Focused regression failed.' }
    row = TestQualityInventory.entries(path => review).first

    assert_equal({ 'path' => path, **review }, row)
    assert_includes TestQualityInventory.render([row]), 'Missing refusal assertion.'
  end

  def test_unknown_status_is_rejected
    assert_raises(ArgumentError) { TestQualityInventory.entries(TestSuite.files.first => { 'status' => 'assumed' }) }
  end

  def test_review_records_referencing_missing_files_are_rejected
    stale = 'test/deleted_subject_test.rb'

    error = assert_raises(ArgumentError) { TestQualityInventory.reject_stale_records!(stale => { 'status' => 'fine' }) }

    assert_includes error.message, stale
  end
end
