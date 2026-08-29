# frozen_string_literal: true

# Generate documentation/adr/relationships.md — a Mermaid graph of the supersession and
# amendment edges between ADRs, derived from catalog.json so it stays in sync. Stdlib only.
#
#   ruby script/adr_graph.rb        # write relationships.md
#
# Wired as `rake adr:graph`.

require "json"

ADR_DIR = File.expand_path("../documentation/adr", __dir__)
catalog = JSON.parse(File.read(File.join(ADR_DIR, "catalog.json"), encoding: Encoding::UTF_8))
adrs = catalog["adrs"]
by = adrs.to_h { |a| [a["num"], a] }

involved = []
edges = []   # [from, to, label, kind]
adrs.each do |a|
  a["superseded_by"].each { |t| edges << [a["num"], t, "superseded by", :solid]; involved << a["num"] << t }
  a["amended_by"].each   { |t| edges << [a["num"], t, "amended by",    :dashed]; involved << a["num"] << t }
end
involved.uniq!

lines = []
lines << "# ADR relationships"
lines << ""
lines << "Supersession and amendment edges between ADRs, generated from"
lines << "[`catalog.json`](./catalog.json) by `script/adr_graph.rb` (`rake adr:graph`). An arrow"
lines << "points from a decision to the ADR that replaced or amended it. Retired decisions are"
lines << "marked; everything not shown here stands on its own."
lines << ""
lines << "```mermaid"
lines << "graph LR"
involved.sort_by(&:to_i).each do |num|
  a = by[num]
  short = a["title"].sub(/^ADR-\d{3}\s*[—-]\s*/, "").split(/[;:—]/).first.to_s.tr("`\"", "").strip[0, 34]
  label = "ADR-#{num}<br/>#{short}"
  if a["state"] == "retired"
    lines << "  A#{num}[\"#{label}\"]:::retired"
  else
    lines << "  A#{num}[\"#{label}\"]"
  end
end
edges.each do |from, to, label, kind|
  arrow = kind == :dashed ? "-.->|#{label}|" : "-->|#{label}|"
  lines << "  A#{from} #{arrow} A#{to}"
end
lines << "  classDef retired fill:#eee,stroke:#999,color:#666,stroke-dasharray:3 3;"
lines << "```"
lines << ""
lines << "Solid = superseded (no longer in force). Dashed = amended/extended/revised (still in"
lines << "force, refined by a later ADR). Full history: [`RETIRED.md`](./RETIRED.md)."
lines << ""
lines << "## Next reads"
lines << ""
lines << "- [`README.md`](./README.md) — the ADR catalog and its amendment-chain list"
lines << "- [`catalog.json`](./catalog.json) — the machine-readable edges"

File.write(File.join(ADR_DIR, "relationships.md"), lines.join("\n") + "\n")
puts "wrote relationships.md (#{involved.size} nodes, #{edges.size} edges)"
