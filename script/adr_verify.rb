# frozen_string_literal: true

# Checks every ADR's Verification evidence still exists: each backticked repo path and `tamoz-*` gem,
# and each backticked `test_*` name, which must be defined in a test file cited on the same row.
# Text near a citation that asserts absence ("does not exist", "was removed") flips the path check.
#
#   ruby script/adr_verify.rb [dir]    # exit 0 when every citation holds, else 1

# Resolves each Verification citation against the repository.
module AdrVerify
  ROOT = File.expand_path('..', __dir__)
  DEFAULT_DIR = File.join(ROOT, 'documentation', 'adr')
  ABSENCE = /\babsent\b|does not exist|returns? zero|zero matches|no longer exists|was removed/i
  PATH = %r{\A(?:gems|documentation|docs|script|test|\.github)/[\w./-]+\z}
  GEM = /\Atamoz-[a-z0-9]+(?:-[a-z0-9]+)*\z/
  TEST_NAME = /\Atest_\w+\z/

  module_function

  def run(dir = DEFAULT_DIR)
    sections(dir).flat_map do |base, section|
      section.each_line.flat_map { |line| check_line(base, line) }
    end
  end

  def citations(dir = DEFAULT_DIR)
    sections(dir).sum do |_, section|
      section.scan(/`([^`]+)`/).flatten.count { |token| target(token) || TEST_NAME.match?(token) }
    end
  end

  def sections(dir)
    Dir[File.join(dir, 'adr-*.md')].filter_map do |path|
      section = File.read(path, encoding: Encoding::UTF_8)[/^##\s+Verification\s*\n(.+?)(?=^##\s|\z)/m, 1]
      [File.basename(path), section] if section
    end
  end

  def check_line(base, line)
    tokens = line.scan(/`([^`]+)`/).flatten.map(&:strip)
    test_files = tokens.select { |token| token.start_with?('test/') && token.end_with?('.rb') }
    cell_tokens(line).filter_map { |cell, token| path_problem(base, cell, token) } +
      tokens.grep(TEST_NAME).filter_map { |name| test_problem(base, name, test_files) }
  end

  def cell_tokens(line)
    line.split('|').flat_map { |cell| cell.scan(/`([^`]+)`/).flatten.map { |token| [cell, token.strip] } }
  end

  def target(token)
    return File.join(ROOT, token) if PATH.match?(token)

    File.join(ROOT, 'gems', token) if GEM.match?(token)
  end

  # Absence wording exempts only the citations in its own table cell.
  def path_problem(base, cell, token)
    path = target(token)
    return unless path

    absent = cell.match?(ABSENCE)
    return "#{base}: Verification says `#{token}` is absent, but it exists" if absent && File.exist?(path)

    "#{base}: Verification cites `#{token}`, which does not exist" unless absent || File.exist?(path)
  end

  def test_problem(base, name, test_files)
    return "#{base}: `#{name}` is cited with no test file on the same row" if test_files.empty?

    defined = test_files.any? do |file|
      path = File.join(ROOT, file)
      File.exist?(path) && File.read(path, encoding: Encoding::UTF_8).match?(/^\s*def #{name}\b/)
    end
    "#{base}: `#{name}` is not defined in #{test_files.join(', ')}" unless defined
  end
end

if $PROGRAM_NAME == __FILE__
  dir = ARGV.first || AdrVerify::DEFAULT_DIR
  problems = AdrVerify.run(dir)
  abort "ADR verification FAILED (#{problems.size}):\n#{problems.map { |p| "  - #{p}" }.join("\n")}" if problems.any?

  puts "adr:verify passed — #{AdrVerify.citations(dir)} evidence citations all hold"
end
