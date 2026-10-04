# frozen_string_literal: true

require 'json'
require_relative '../../test/support/test_suite'

# Renders docs/test-quality/TEST_TRACKER.{json,md} from reviews.json, the
# per-file audit tracker for the test improvement program.
module TestQualityInventory
  ROOT = TestSuite::ROOT
  DIRECTORY = File.join(ROOT, 'docs/test-quality')
  STATUSES = ['needs improvement', 'needs review', 'fine', 'done'].freeze

  module_function

  def entries(reviews)
    TestSuite.files.map do |path|
      review = reviews.fetch(path, { 'status' => 'needs review', 'reason' => 'Static inventory only.' })
      raise ArgumentError, "invalid status for #{path}" unless STATUSES.include?(review.fetch('status'))

      { 'path' => path, **review }
    end
  end

  def render(rows)
    counts = rows.map { |row| row.fetch('status') }.tally
    summary = STATUSES.map { |status| "#{status}: #{counts.fetch(status, 0)}" }.join(' · ')
    lines = ['# Test file tracker', '', summary, '',
             'Generated from `reviews.json` by `ruby script/quality/test_inventory.rb`.', '',
             'Done means the recorded improvement passed focused checks and independent review.',
             'Fine means the reviewed file needs no change. Neither status means the whole suite passed.',
             'Needs review is deliberately separate from a confirmed defect.', '',
             '| Test file | Status | Finding / completed work | Verification |',
             '| --- | --- | --- | --- |']
    rows.each do |row|
      lines << "| [#{row.fetch('path')}](../../#{row.fetch('path')}) | #{row.fetch('status')} | " \
               "#{cell(row.fetch('reason'))} | #{cell(row.fetch('verification', 'Not verified individually.'))} |"
    end
    "#{lines.join("\n")}\n"
  end

  def cell(value)
    value.gsub('|', '\\|').tr("\n", ' ')
  end

  def write
    reviews = JSON.parse(File.read(File.join(DIRECTORY, 'reviews.json')))
    reject_stale_records!(reviews)
    rows = entries(reviews)
    File.write(File.join(DIRECTORY, 'TEST_TRACKER.json'), "#{JSON.pretty_generate(rows)}\n")
    File.write(File.join(DIRECTORY, 'TEST_TRACKER.md'), render(rows))
    puts "Tracked #{rows.length} test files: #{rows.map { |row| row.fetch('status') }.tally}"
  end

  def reject_stale_records!(reviews)
    stale = reviews.keys - TestSuite.files
    return if stale.empty?

    raise ArgumentError, "review records reference missing files: #{stale.join(', ')}"
  end
end

TestQualityInventory.write if $PROGRAM_NAME == __FILE__
