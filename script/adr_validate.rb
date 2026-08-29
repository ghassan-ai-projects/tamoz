# frozen_string_literal: true

# Consistency checks for the ADR catalog under documentation/adr/. Stdlib only.
# Enforces ADR_QUALITY_BAR.md so the drift the 2026-08-29 audit found cannot silently return.
#
#   ruby script/adr_validate.rb        # exit 0 if clean, 1 with a list of failures
#
# Wired as `rake adr:validate`.

require "json"
require "set"

ADR_DIR = File.expand_path("../documentation/adr", __dir__)
failures = []
warnings = []

def slug(h)
  h = h.strip.downcase
  h = h.gsub(/[^\w\s-]/, "")
  h.gsub(/\s/, "-")
end

files = Dir[File.join(ADR_DIR, "adr-*.md")].sort
adrs = {}   # num -> {path, text, h1num, title, status, state, sections, anchors}

files.each do |path|
  text = File.read(path, encoding: Encoding::UTF_8)
  base = File.basename(path)
  fnum = base[/^adr-(\d{3})-/, 1]
  h1s = text.scan(/^\#\s+(.+)$/)
  failures << "#{base}: expected exactly one H1, found #{h1s.size}" if h1s.size != 1
  h1 = h1s.flatten.first.to_s
  h1num = h1[/ADR-(\d{3})\b/, 1]
  failures << "#{base}: H1 does not start with '# ADR-NNN — '" unless h1 =~ /^ADR-\d{3} — /
  failures << "#{base}: filename number #{fnum} != H1 number #{h1num}" if fnum && h1num && fnum != h1num
  status = text[/^\*\*Status:\*\*\s*(.+)$/, 1].to_s.strip
  failures << "#{base}: missing **Status:**" if status.empty?
  unless status =~ /^(Accepted|Proposed|Retired)\b/
    failures << "#{base}: Status must start with Accepted|Proposed|Retired (got #{status[0, 30].inspect})"
  end
  state = if status =~ /^Retired/i || h1 =~ /\(RETIRED\)/ then "retired"
          elsif status =~ /\bProposed\b/ then "proposed" else "accepted" end
  sections = text.scan(/^\#\#\s+(?:\d+\.\s+)?(.+)$/).flatten.map(&:strip)
  anchors = text.scan(/^\#{1,6}\s+(.+)$/).flatten.map { |h| slug(h) }.to_set
  adrs[fnum] = { path: path, base: base, text: text, h1num: h1num, title: h1,
                 status: status, state: state, sections: sections, anchors: anchors }
end

# unique numbers, completeness 1..max
nums = adrs.keys.map(&:to_i).sort
dupes = nums.group_by(&:itself).select { |_, v| v.size > 1 }.keys
failures << "duplicate ADR numbers: #{dupes.inspect}" unless dupes.empty?
(1..(nums.max || 0)).each do |n|
  failures << "no file for ADR-#{format('%03d', n)} (every number must resolve to a file/tombstone)" unless adrs.key?(format("%03d", n))
end

# per-ADR structure + supersession
adrs.each do |num, a|
  if a[:state] == "retired"
    failures << "ADR-#{num} (retired) names no successor in Status" unless a[:status] =~ /(superseded|revised|amended) by \[ADR-\d{3}/i
    ret = File.read(File.join(ADR_DIR, "RETIRED.md"), encoding: Encoding::UTF_8) rescue ""
    failures << "ADR-#{num} (retired) has no row in RETIRED.md" unless ret =~ /\*\*#{num}\*\*|\bADR-#{num}\b|\b#{num}\b/
  else
    %w[Context Decision Consequences].each do |sec|
      failures << "ADR-#{num}: in-force ADR missing '## #{sec}'" unless a[:sections].include?(sec)
    end
    warnings << "ADR-#{num}: accepted ADR has no '## Verification' section" if a[:state] == "accepted" && !a[:sections].include?("Verification")
  end
  # amendment/supersession targets must exist
  a[:status].scan(/\[ADR-(\d{3})/).flatten.each do |t|
    failures << "ADR-#{num}: references ADR-#{t} which has no file" unless adrs.key?(t)
  end
end

# link + anchor resolution across the whole adr dir
Dir[File.join(ADR_DIR, "*.md")].each do |path|
  text = File.read(path, encoding: Encoding::UTF_8)
  base = File.basename(path)
  text.scan(/\]\(([^)]+)\)/).flatten.each do |target|
    next if target =~ %r{\Ahttps?://} || target.start_with?("mailto:")
    rel, anchor = target.split("#", 2)
    if rel.nil? || rel.empty?
      # same-file anchor
      here = text.scan(/^\#{1,6}\s+(.+)$/).flatten.map { |h| slug(h) }.to_set
      failures << "#{base}: dead self-anchor ##{anchor}" if anchor && !here.include?(anchor)
      next
    end
    resolved = File.expand_path(rel, File.dirname(path))
    unless File.exist?(resolved)
      failures << "#{base}: broken link #{target}"
      next
    end
    if anchor && resolved.end_with?(".md")
      htext = File.read(resolved, encoding: Encoding::UTF_8)
      hs = htext.scan(/^\#{1,6}\s+(.+)$/).flatten.map { |h| slug(h) }.to_set
      failures << "#{base}: dead anchor #{target}" unless hs.include?(anchor)
    end
  end
end

# README index coverage
readme = File.read(File.join(ADR_DIR, "README.md"), encoding: Encoding::UTF_8)
indexed = readme.scan(/^\|\s*\[(\d{3})\]/).flatten.to_set
adrs.each_key { |num| failures << "ADR-#{num} is not listed in README index" unless indexed.include?(num) }
indexed.each { |num| failures << "README lists ADR-#{num} but no file exists" unless adrs.key?(num) }

# catalog.json in sync
catalog_check = system("ruby", File.join(__dir__, "adr_catalog.rb"), "--check", out: File::NULL, err: File::NULL)
failures << "catalog.json is stale — run: ruby script/adr_catalog.rb" unless catalog_check

# report
warnings.each { |w| warn "WARN  #{w}" }
if failures.empty?
  puts "adr:validate passed — #{adrs.size} ADRs, #{warnings.size} warning(s), next number #{(nums.max || 0) + 1}"
else
  warn "\nADR validation FAILED (#{failures.size}):"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
