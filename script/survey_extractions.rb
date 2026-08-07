#!/usr/bin/env ruby
# frozen_string_literal: true

# Rank the largest production files by EXTRACTION COST, cheapest first.
#
# One signal has predicted a cheap refactoring slice every time: a NESTED
# class or module that can move to its own file more or less verbatim. That is
# what made the profile.rb registries, CheckpointWire and CheckpointWriter
# quick, and its absence is what makes session_nodes.rb and toolbox.rb slow —
# there, every extraction is a design decision instead of a move.
#
# Run from the repository root. Needs a UTF-8 locale:
#
#   LANG=en_US.UTF-8 rbenv exec ruby script/survey_extractions.rb
#
# Read the output as candidates, not conclusions. Two false positives recur and
# must be filtered by eye: a SQL heredoc containing `class TEXT NOT NULL`, and
# a file's own namespace when it nests deeper than four spaces.

TOP_FILES = 50
MIN_NESTED_LINES = 25

# :reek:UtilityFunction — this is a script, not an object graph.
def production_files
  Dir.glob('gems/*/lib/**/*.rb')
     .reject { |path| path.include?('/evals/harness/') }
     .sort_by { |path| -File.readlines(path).size }
     .first(TOP_FILES)
end

# A definition indented deeper than the file's own namespace, paired with the
# `end` at its own indent so the size is real rather than guessed.
#
# :reek:TooManyStatements — one scan with one match per line.
# :reek:UtilityFunction — this is a script, not an object graph.
# :reek:NestedIterators — the inner scan looks ahead for the matching `end`.
def nested_definitions(lines)
  lines.each_with_index.filter_map do |line, index|
    match = line.match(/^(\s+)(class|module)\s+([A-Z]\w*)/)
    next unless match

    indent = match[1].length
    next if indent <= 4

    lineno = index + 1
    closing = lines[lineno..].index { |candidate| candidate.rstrip == "#{' ' * indent}end" }
    next unless closing

    { name: match[3], kind: match[2], line: lineno, size: closing + 2 }
  end
end

# :reek:FeatureEnvy :reek:TooManyStatements — a formatter reads the thing it
# formats and prints one line per field.
def report(path, definitions)
  puts "#{path.sub('gems/', '').ljust(58)} #{File.readlines(path).size} lines"
  ordered = definitions.sort_by { |definition| -definition.fetch(:size) }
  ordered.each do |definition|
    name, kind, line, size = definition.values_at(:name, :kind, :line, :size)
    puts "    #{name.ljust(26)} #{kind.ljust(7)} ~#{size} lines @ #{line}"
  end
end

candidates = production_files.filter_map do |path|
  definitions = nested_definitions(File.readlines(path)).select { |d| d[:size] >= MIN_NESTED_LINES }
  [path, definitions] unless definitions.empty?
end

puts "Nested definitions of at least #{MIN_NESTED_LINES} lines, in the #{TOP_FILES} largest files."
puts 'Cheapest slices first: more nested lines means more that can move verbatim.'
puts
candidates
  .sort_by { |_, definitions| -definitions.sum { |d| d[:size] } }
  .each { |path, definitions| report(path, definitions) }
