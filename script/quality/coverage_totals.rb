# frozen_string_literal: true

# Shared SimpleCov resultset aggregation for the quality program (Q0-5 / Q1).
# script/regenerate_quality_baseline and `rake quality:coverage` must compute
# identical numbers, so the logic lives here. Files are merged across processes
# by taking the max coverage of each line/branch; a branch leaf is covered when
# its hit count is positive.
module QualityCoverage
  module_function

  def totals(resultset_path)
    merged = merge_resultset(JSON.parse(File.read(resultset_path)))
    line_hit, line_total = line_totals(merged)
    branch_hit, branch_total = branch_totals(merged)
    {
      'line_percent' => percent(line_hit, line_total),
      'line_covered' => line_hit,
      'line_total' => line_total,
      'branch_percent' => percent(branch_hit, branch_total),
      'branch_covered' => branch_hit,
      'branch_total' => branch_total,
      'uncovered_files' => uncovered_files(merged)
    }
  end

  def merge_resultset(resultset)
    resultset.each_value.reduce({}) { |merged, command| merge_command(merged, command) }
  end

  def merge_command(merged, command)
    command.fetch('coverage').each_with_object(merged) do |(path, data), acc|
      entry = (acc[path] ||= { 'lines' => [], 'branches' => {} })
      entry['lines'] = merge_line_arrays(entry.fetch('lines'), data.fetch('lines'))
      entry['branches'] = merge_branch_trees(entry.fetch('branches'), data.fetch('branches', {}))
    end
  end

  def merge_line_arrays(left, right)
    longer, shorter = left.size > right.size ? [left, right] : [right, left]
    longer.zip(shorter).map { |left_value, right_value| [left_value, right_value].compact.max }
  end

  def merge_hash_trees(target, source)
    source.each_with_object(target.dup) do |(key, value), merged|
      merged[key] = target.key?(key) ? merge_branch_trees(target.fetch(key), value) : value
    end
  end

  def merge_branch_trees(left, right)
    case right
    when Hash
      merge_hash_trees(left, right)
    when Numeric
      left.is_a?(Numeric) ? [left, right].max : right
    else
      left
    end
  end

  def line_counts_for(data)
    relevant = data.fetch('lines').compact
    [relevant.count { |value| value.to_i.positive? }, relevant.size]
  end

  def line_totals(merged)
    merged.each_value.reduce([0, 0]) do |(hit, total), data|
      covered, size = line_counts_for(data)
      [hit + covered, total + size]
    end
  end

  def branch_totals(merged)
    counts = { hit: 0, total: 0 }
    merged.each_value { |data| branch_counts(data.fetch('branches'), counts) }
    [counts[:hit], counts[:total]]
  end

  def branch_counts(node, counts)
    case node
    when Hash
      node.each_value { |value| branch_counts(value, counts) }
    when Numeric
      counts[:total] += 1
      counts[:hit] += 1 if node.positive?
    end
  end

  def uncovered?(data)
    relevant = data.fetch('lines').compact
    relevant.size.positive? && relevant.none? { |value| value.to_i.positive? }
  end

  def uncovered_files(merged)
    merged.select { |_path, data| uncovered?(data) }.map { |path, _data| path }.sort
  end

  def percent(hit, total)
    total.zero? ? 0.0 : (hit.to_f / total * 100).round(2)
  end
end
