# frozen_string_literal: true

module SourceBoundaryAudit
  private

  def matches(path, pattern)
    File.readlines(ROOT.join(path), encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
      next unless line.valid_encoding? && !line.match?(/\A\s*#/)

      "#{path}:#{index + 1}: #{line.strip}" if line.match?(pattern)
    end
  rescue ArgumentError
    []
  end
end
