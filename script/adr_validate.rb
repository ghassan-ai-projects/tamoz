# frozen_string_literal: true

# Mechanical checks for documentation/adr/ (ADR_QUALITY_BAR.md §7): numbering, header fields,
# sections per tier, banned boilerplate, reciprocal relations, links, index coverage, catalog sync.
# Whether an ADR is true is a review, not something this can check.
#
#   ruby script/adr_validate.rb [dir]    # exit 0 when clean, 1 with the failures

require_relative 'adr_catalog'

# Per-record and corpus checks; `run` returns the failures as strings.
module AdrValidate
  DATE = /\A\d{4}-\d{2}-\d{2}\z/
  SUCCESSOR = /\[ADR-\d{3}\]\([^)]+\)/
  STATUSES = [
    /\AAccepted \d{4}-\d{2}-\d{2}\z/,
    /\AProposed\z/,
    /\ARetired \d{4}-\d{2}-\d{2} — superseded by #{SUCCESSOR}(?: and #{SUCCESSOR})*\z/o,
    /\ARetired \d{4}-\d{2}-\d{2} — withdrawn\z/
  ].freeze
  IMPLEMENTATION = /\A(?:Complete(?: — .+)?|Partial — .+|Not built(?: — .+)?)\z/
  RELATION_KEYS = ['Status', 'Relates to', 'Amends', 'Amended by', 'Supersedes'].freeze
  SECTIONS = {
    'C' => ['Context', 'Decision', 'Consequences', 'Rejected alternatives', 'Reopen when', 'Verification'],
    'F' => ['Context', 'Decision', 'Consequences', 'Invariants', 'Threat model', 'Rejected alternatives',
            'Reopen when', 'Verification']
  }.freeze
  OPTIONAL_SECTIONS = ['History', 'Next reads'].freeze
  BANNED = {
    /^Current version:/ => 'release-version boilerplate',
    /\benola:\s*\d+\s+dependents\b/i => 'a fan-in count as evidence',
    /\bfan-in\s+\d+/i => 'a fan-in count as evidence',
    /Recommended follow-up/i => 'an open TODO in the record',
    /^##\s+\d+\./ => 'a numbered section heading'
  }.freeze

  module_function

  def run(dir)
    files = Dir[File.join(dir, 'adr-*.md')]
    adrs = files.to_h { |path| [File.basename(path)[/\Aadr-(\d{3})-/, 1], AdrCatalog.parse(path)] }
    [*numbering(files), *adrs.flat_map { |num, adr| record(dir, num, adr, adrs) }, *Corpus.run(dir, adrs)]
  end

  def numbering(files)
    nums = files.map { |path| File.basename(path)[/\Aadr-(\d{3})-/, 1] }
    dupes = nums.tally.select { |_, count| count > 1 }.keys
    gaps = (1..nums.map(&:to_i).max.to_i).map { |n| format('%03d', n) } - nums
    dupes.map { |num| "duplicate ADR number #{num}" } +
      gaps.map { |num| "no file for ADR-#{num} (every number keeps a file or tombstone)" }
  end

  def record(dir, num, adr, adrs)
    text = File.read(File.join(dir, adr['file']), encoding: Encoding::UTF_8)
    heading(num, text) + status(num, adr) + headers(num, text) +
      (adr['state'] == 'retired' ? retired(dir, num, adr, adrs) : in_force(num, adr, text))
  end

  def headers(num, text)
    lines = text.scan(AdrCatalog::HEADER)
    dupes = lines.map(&:first).tally.select { |_, count| count > 1 }.keys
    unlinked = lines.to_h.slice(*RELATION_KEYS).flat_map do |key, value|
      value.scan(/(?<!\[)ADR-\d{3}/).map { |ref| "ADR-#{num}: #{key} names #{ref} without linking it" }
    end
    dupes.map { |key| "ADR-#{num}: header '#{key}' appears more than once" } + unlinked
  end

  def heading(num, text)
    h1s = text.scan(/^#\s+(.+)$/).flatten
    return ["ADR-#{num}: expected exactly one H1, found #{h1s.size}"] unless h1s.size == 1
    return [] if h1s.first.start_with?("ADR-#{num} — ")

    ["ADR-#{num}: H1 must start with 'ADR-#{num} — '"]
  end

  def status(num, adr)
    return [] if STATUSES.any? { |pattern| pattern.match?(adr['status']) }

    ["ADR-#{num}: Status #{adr['status'][0, 40].inspect} is not a bar §2 value"]
  end

  def retired(dir, num, adr, adrs)
    ledger = File.read(File.join(dir, 'RETIRED.md'), encoding: Encoding::UTF_8)
    missing = adr['superseded_by'].reject { |target| adrs.key?(target) }
    (ledger.include?("**#{num}**") ? [] : ["ADR-#{num}: retired but has no RETIRED.md row"]) +
      missing.map { |target| "ADR-#{num}: successor ADR-#{target} has no file" } +
      (DATE.match?(adr['date'].to_s) ? [] : ["ADR-#{num}: Date must be YYYY-MM-DD"]) +
      (adr['sections'].empty? ? [] : ["ADR-#{num}: a tombstone keeps no sections"])
  end

  def in_force(num, adr, text)
    fields(num, adr) + sections(num, adr) + banned(num, text) + cost(num, text)
  end

  def cost(num, text)
    consequences = text[/^##\s+Consequences\s*\n(.+?)(?=^##\s|\z)/m, 1].to_s
    consequences.include?('**Cost:**') ? [] : ["ADR-#{num}: Consequences must state a **Cost:**"]
  end

  def fields(num, adr)
    problems = []
    problems << "ADR-#{num}: Date must be YYYY-MM-DD" unless DATE.match?(adr['date'].to_s)
    problems << "ADR-#{num}: Tier must be C or F" unless SECTIONS.key?(adr['tier'])
    unless IMPLEMENTATION.match?(adr['implementation'].to_s)
      problems << "ADR-#{num}: Implementation must be Complete, Partial — <gap>, or Not built"
    end
    problems
  end

  def sections(num, adr)
    required = SECTIONS.fetch(adr['tier'], [])
    present = adr['sections']
    missing = required - present
    unknown = present - required - OPTIONAL_SECTIONS
    ordered = present & required
    missing.map { |name| "ADR-#{num}: missing '## #{name}'" } +
      unknown.map { |name| "ADR-#{num}: unexpected section '## #{name}'" } +
      (missing.empty? && ordered != required ? ["ADR-#{num}: sections are out of order"] : [])
  end

  def banned(num, text)
    BANNED.filter_map { |pattern, why| "ADR-#{num}: contains #{why}" if pattern.match?(text) }
  end

  # Checks across the corpus: reciprocal relations, links, index coverage, catalog sync.
  module Corpus
    RELATIONS = [
      ['amends', 'amended_by', 'Amends', 'Amended by'],
      ['amended_by', 'amends', 'Amended by', 'Amends'],
      ['supersedes', 'superseded_by', 'Supersedes', 'superseded by'],
      ['superseded_by', 'supersedes', 'superseded by', 'Supersedes']
    ].freeze

    module_function

    def run(dir, adrs) = [*relations(adrs), *links(dir), *index(dir, adrs.keys), *catalog(dir)]

    def relations(adrs)
      adrs.flat_map do |num, adr|
        RELATIONS.flat_map { |relation| reciprocal(num, adr, adrs, relation) }
      end
    end

    def reciprocal(num, adr, adrs, (forward, reverse, said, expected))
      adr[forward].filter_map do |target|
        other = adrs[target]
        next "ADR-#{num}: #{said} ADR-#{target}, which has no file" unless other
        next if other[reverse].include?(num)

        "ADR-#{num}: #{said} ADR-#{target}, but ADR-#{target} has no '#{expected} ADR-#{num}'"
      end
    end

    def links(dir)
      Dir[File.join(dir, '*.md')].reject { |path| File.basename(path) == '_TEMPLATE.md' }.flat_map do |path|
        text = File.read(path, encoding: Encoding::UTF_8)
        prose = text.gsub(/^```.*?^```/m, '').gsub(/`[^`\n]*`/, '')
        prose.scan(/\]\(([^)\s]+)\)/).flatten.filter_map { |target| dead_link(path, text, target) }
      end
    end

    def dead_link(path, text, target)
      return if target.match?(/\A(?:https?|mailto):/)

      rel, anchor = target.split('#', 2)
      resolved = rel.to_s.empty? ? path : File.expand_path(rel, File.dirname(path))
      return "#{File.basename(path)}: broken link #{target}" unless File.exist?(resolved)
      return unless anchor && resolved.end_with?('.md')

      body = resolved == path ? text : File.read(resolved, encoding: Encoding::UTF_8)
      "#{File.basename(path)}: dead anchor #{target}" unless anchors(body).include?(anchor)
    end

    def anchors(text)
      headings = text.scan(/^\#{1,6}\s+(.+)$/).flatten
      headings.to_set { |heading| heading.strip.downcase.gsub(/[^\w\s-]/, '').tr(' ', '-') }
    end

    def index(dir, nums)
      readme = File.read(File.join(dir, 'README.md'), encoding: Encoding::UTF_8)
      indexed = readme.scan(/^\|\s*\[(\d{3})\]/).flatten
      (nums - indexed).map { |num| "ADR-#{num} is not listed in the README index" } +
        (indexed - nums).map { |num| "README lists ADR-#{num} but no file exists" } +
        indexed.tally.select { |_, count| count > 1 }.keys.map { |num| "README lists ADR-#{num} twice" }
    end

    def catalog(dir)
      AdrCatalog.current?(dir) ? [] : ['catalog.json is stale — run: ruby script/adr_catalog.rb']
    end
  end
end

if $PROGRAM_NAME == __FILE__
  dir = ARGV.first || AdrCatalog::DEFAULT_DIR
  failures = AdrValidate.run(dir)
  build = AdrCatalog.build(dir)
  abort "ADR validation FAILED (#{failures.size}):\n#{failures.map { |f| "  - #{f}" }.join("\n")}" if failures.any?

  puts "adr:validate passed — #{build['count']} ADRs, next number #{build['next_number']}"
end
