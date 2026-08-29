# frozen_string_literal: true

# Generate documentation/adr/catalog.json — a machine-readable index of every ADR, parsed
# from the ADR files themselves (no second source of truth to hand-maintain). Stdlib only.
#
#   ruby script/adr_catalog.rb            # write catalog.json
#   ruby script/adr_catalog.rb --check    # fail (exit 1) if catalog.json is stale
#
# Also used by `rake adr:validate` (see script/adr_validate.rb).

require "json"

ADR_DIR = File.expand_path("../documentation/adr", __dir__)
CATALOG = File.join(ADR_DIR, "catalog.json")

def parse_adr(path)
  text = File.read(path, encoding: Encoding::UTF_8)
  h1 = text[/^\#\s+(.+)$/, 1].to_s.strip
  num = File.basename(path)[/^adr-(\d{3})-/, 1]
  status_line = text[/^\*\*Status:\*\*\s*(.+)$/, 1].to_s.strip
  date = text[/^\*\*Date:\*\*\s*([0-9]{4}-[0-9]{2}-[0-9]{2})/, 1] ||
         status_line[/([0-9]{4}-[0-9]{2}-[0-9]{2})/, 1]
  tier = text[/^\*\*Tier:\*\*\s*([A-Z])/, 1]
  relates = text[/^\*\*Relates to:\*\*\s*(.+)$/, 1].to_s.scan(/ADR-(\d{3})/).flatten

  state =
    if status_line =~ /^Retired\b/i || h1 =~ /\(RETIRED\)/ then "retired"
    elsif status_line =~ /\bProposed\b/ then "proposed"
    else "accepted"
    end

  # amendment / supersession targets named in the status line — tolerate markdown emphasis
  # ("**revised** by") and multi-target lists ("superseded by [A] and [B]").
  rel = lambda do |verbs|
    m = status_line.match(/\b(?:#{verbs})\b\*{0,2}\s+by\b/i)
    m ? status_line[m.end(0)..].scan(/ADR-(\d{3})/).flatten : []
  end
  superseded_by = rel.call("superseded")
  amended_by = (rel.call("revised|amended|extended|completed|instantiated") - superseded_by)

  sections = text.scan(/^\#\#\s+(?:\d+\.\s+)?(.+)$/).flatten.map(&:strip)
  ver = text[/^\#\#\s+(?:\d+\.\s+)?Verification\s*\n+(.+?)(?:\n\#\#\s|\z)/m, 1].to_s.strip

  {
    "num" => num,
    "id" => num.to_i,
    "title" => h1.sub(/\s*\(RETIRED\)\s*$/, "").strip,
    "status" => status_line,
    "state" => state,
    "date" => date,
    "tier" => tier,
    "file" => File.basename(path),
    "relates_to" => relates.sort.uniq,
    "superseded_by" => superseded_by.sort.uniq,
    "amended_by" => amended_by.sort.uniq,
    "verified" => !ver.empty?,
    "sections" => sections
  }
end

def build
  adrs = Dir[File.join(ADR_DIR, "adr-*.md")].sort.map { |p| parse_adr(p) }
  # inverse edges
  by_num = adrs.to_h { |a| [a["num"], a] }
  adrs.each { |a| a["supersedes"] = []; a["amends"] = [] }
  adrs.each do |a|
    a["superseded_by"].each { |t| by_num[t] && (by_num[t]["supersedes"] << a["num"]) }
    a["amended_by"].each   { |t| by_num[t] && (by_num[t]["amends"] << a["num"]) }
  end
  adrs.each { |a| a["supersedes"].sort!; a["amends"].sort! }
  nums = adrs.map { |a| a["id"] }
  {
    "generated_by" => "script/adr_catalog.rb",
    "count" => adrs.size,
    "next_number" => (nums.max || 0) + 1,
    "states" => adrs.group_by { |a| a["state"] }.transform_values(&:size),
    "adrs" => adrs
  }
end

json = JSON.pretty_generate(build) + "\n"

if ARGV.include?("--check")
  current = File.exist?(CATALOG) ? File.read(CATALOG, encoding: Encoding::UTF_8) : ""
  if current == json
    puts "catalog.json is up to date (#{JSON.parse(json)["count"]} ADRs)"
  else
    warn "catalog.json is STALE — run: ruby script/adr_catalog.rb"
    exit 1
  end
else
  File.write(CATALOG, json)
  puts "wrote #{CATALOG} (#{JSON.parse(json)["count"]} ADRs)"
end
