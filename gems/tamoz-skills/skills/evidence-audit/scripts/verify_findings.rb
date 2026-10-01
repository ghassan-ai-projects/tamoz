#!/usr/bin/env ruby
# frozen_string_literal: true

# Verifies an evidence-audit findings file against the workspace it cites.
#   ruby verify_findings.rb [--reviewed] [--root DIR] [--json] audit/findings.json
# Exit 0 when every rule holds; 1 with every problem listed, so all of them can be fixed at once.

require "digest"
require "json"
require "time"

module EvidenceAudit
  CONCLUSIONS = %w[exception no_exception insufficient_evidence].freeze
  SEVERITIES = %w[high medium low info].freeze
  STATUSES = %w[proposed accepted rejected needs_more_evidence].freeze
  MAX_SPAN = 10
  MIN_QUOTE = 20
  MAX_CITATIONS = 3
  FINDING_ID = /\AF-\d{3}\z/

  def self.normalize(text) = text.to_s.gsub(/\s+/, " ").strip

  # Where a quote really is: the smallest line range inside `lines` (1-based, inclusive) that holds it.
  def self.locate(file_lines, quote, first = 1, last = file_lines.length)
    wanted = normalize(quote)
    return nil if wanted.empty?

    (0...MAX_SPAN).each do |span|
      (first..(last - span)).each do |start|
        return [start, start + span] if normalize(file_lines[(start - 1)..(start + span - 1)].join(" ")).include?(wanted)
      end
    end
    nil
  end

  Result = Data.define(:problems, :document) do
    def ok? = problems.empty?
  end

  class Verifier
    def initialize(findings_path, root: Dir.pwd, reviewed: false)
      @findings_path = findings_path
      @root = File.expand_path(root)
      @reviewed = reviewed
      @problems = []
      @lines = {}
    end

    def call
      document = parse
      check(document) if document
      Result.new(problems: @problems.freeze, document:)
    end

    private

    def parse
      document = JSON.parse(File.read(File.expand_path(@findings_path, @root)))
      return document if document.is_a?(Hash)

      problem("findings file must be a JSON object")
    rescue JSON::ParserError => e
      problem("findings file is not valid JSON: #{e.message[0, 200]}")
    rescue SystemCallError
      problem("findings file #{@findings_path} does not exist")
    end

    def check(document)
      audit = document["audit"]
      problem("audit must name its title and criteria_source") unless audit.is_a?(Hash) &&
                                                                      present?(audit["title"]) &&
                                                                      present?(audit["criteria_source"])
      sources = check_sources(array(document, "sources"))
      criteria = check_criteria(array(document, "criteria"))
      findings = array(document, "findings")
      ids = findings.map { |finding| finding.is_a?(Hash) ? finding["id"] : nil }
      ids.tally.each { |id, count| problem("finding id #{id.inspect} is used #{count} times") if count > 1 }
      findings.each { |finding| check_finding(finding, sources, criteria) }
      covered = findings.filter_map { |finding| finding["criterion"] if finding.is_a?(Hash) }
      (criteria - covered).each { |id| problem("criterion #{id} has no finding") }
      check_consistency(findings)
      check_report(ids.compact)
    end

    def array(document, key)
      value = document[key]
      return value if value.is_a?(Array) && !value.empty?

      problem("#{key} must be a non-empty list")
      []
    end

    def check_sources(sources)
      sources.each_with_object([]) do |source, paths|
        path = source.is_a?(Hash) ? source["path"] : nil
        next problem("each source needs a path and a sha256") unless present?(path) && present?(source["sha256"])
        next unless safe_path?(path, "source")

        content = read(path)
        next problem("source #{path} does not exist") unless content

        expected = source["sha256"].delete_prefix("sha256:")
        actual = Digest::SHA256.hexdigest(content)
        problem("source #{path} changed: recorded sha256 #{expected}, file is #{actual}") unless expected == actual
        paths << path
      end
    end

    def check_criteria(criteria)
      ids = criteria.filter_map { |criterion| criterion["id"] if criterion.is_a?(Hash) && present?(criterion["text"]) }
      problem("every criterion needs an id and its text") unless ids.length == criteria.length
      ids.tally.each { |id, count| problem("criterion id #{id} is used #{count} times") if count > 1 }
      ids.uniq
    end

    def check_finding(finding, sources, criteria)
      return problem("each finding must be an object") unless finding.is_a?(Hash)

      id = finding["id"].to_s
      problem("finding id #{id.inspect} must look like F-001") unless FINDING_ID.match?(id)
      problem("#{id}: criterion #{finding['criterion'].inspect} is not in criteria") unless
        criteria.include?(finding["criterion"])
      check_fields(id, finding)
      evidence = finding["evidence"]
      problem("#{id}: evidence must cite at least one passage") unless evidence.is_a?(Array) && !evidence.empty?
      %w[evidence counter_evidence].each do |key|
        count = Array(finding[key]).length
        problem("#{id}: cite at most #{MAX_CITATIONS} passages in #{key}, not #{count}") if count > MAX_CITATIONS
      end
      Array(evidence).each_with_index { |citation, index| check_citation(id, "evidence[#{index}]", citation, sources) }
      Array(finding["counter_evidence"]).each_with_index do |citation, index|
        check_citation(id, "counter_evidence[#{index}]", citation, sources)
      end
      check_review(id, finding["review"])
    end

# One criterion, one conclusion: a finding cannot hedge by concluding both ways.
def check_consistency(findings)
  findings.select { |finding| finding.is_a?(Hash) }.group_by { |finding| finding["criterion"] }.each do |criterion, group|
    conclusions = group.map { |finding| finding["conclusion"] }.uniq
    problem("criterion #{criterion} has conflicting conclusions: #{conclusions.join(', ')}") if conclusions.length > 1
  end
end

def check_fields(id, finding)
      %w[title statement reasoning].each { |key| problem("#{id}: #{key} is empty") unless present?(finding[key]) }
      conclusion = finding["conclusion"]
      problem("#{id}: conclusion must be one of #{CONCLUSIONS.join(', ')}") unless CONCLUSIONS.include?(conclusion)
      severity = finding["severity"]
      problem("#{id}: severity must be one of #{SEVERITIES.join(', ')}") unless SEVERITIES.include?(severity)
      problem("#{id}: a no_exception finding has severity info") if conclusion == "no_exception" && severity != "info"
    end

    def check_citation(id, label, citation, sources)
      return problem("#{id} #{label}: a citation is {path, lines, quote, supports}") unless citation.is_a?(Hash)

      path, lines, quote = citation.values_at("path", "lines", "quote")
      problem("#{id} #{label}: supports is empty") unless present?(citation["supports"])
      return problem("#{id} #{label}: #{path.inspect} is not a listed source") unless sources.include?(path)
      return unless valid_lines?(id, label, path, lines)
      return problem("#{id} #{label}: the quote must be at least #{MIN_QUOTE} characters") if
        EvidenceAudit.normalize(quote).length < MIN_QUOTE

      locate_quote(id, label, path, lines, quote)
    end

    def valid_lines?(id, label, path, lines)
      total = file_lines(path).length
      unless lines.is_a?(Array) && lines.length == 2 && lines.all?(Integer) && lines[0].between?(1, lines[1]) &&
             lines[1] <= total
        problem("#{id} #{label}: lines must be [first, last] within 1..#{total} of #{path}")
        return false
      end
      return true if lines[1] - lines[0] < MAX_SPAN

      problem("#{id} #{label}: cite at most #{MAX_SPAN} lines, not #{lines[0]}-#{lines[1]}")
      false
    end

    def locate_quote(id, label, path, lines, quote)
      return if EvidenceAudit.locate(file_lines(path), quote, *lines)

      found = EvidenceAudit.locate(file_lines(path), quote)
      where = found ? "it is at lines #{found[0]}-#{found[1]}" : "it is not in the file verbatim"
      problem("#{id} #{label}: the quote is not in #{path} lines #{lines[0]}-#{lines[1]}; #{where}")
    end

    def check_review(id, review)
      return problem("#{id}: review must be {status, reviewer, decided_at, note}") unless review.is_a?(Hash)

      status = review["status"]
      return problem("#{id}: review status must be one of #{STATUSES.join(', ')}") unless STATUSES.include?(status)

      if !@reviewed
        return if status == "proposed" && review["reviewer"].nil? && review["decided_at"].nil?

        problem("#{id}: a prepared finding is proposed with no reviewer or decision; only a person decides it")
      elsif status != "proposed"
        problem("#{id}: a #{status} finding names its reviewer and decided_at") unless
          present?(review["reviewer"]) && time?(review["decided_at"])
      end
    end

    def check_report(ids)
      report = read(File.join(File.dirname(@findings_path), "REPORT.md"))
      return problem("REPORT.md is missing beside the findings file") unless report

      cited = report.scan(/F-\d{3}/).uniq
      (ids - cited).each { |id| problem("REPORT.md does not mention #{id}") }
      (cited - ids).each { |id| problem("REPORT.md mentions #{id}, which is not a finding") }
    end

    def safe_path?(path, what)
      normalized = File.expand_path(path, @root).delete_prefix("#{@root}/")
      unsafe = path.start_with?("/") || path.split("/").include?("..") || normalized.start_with?("audit/") ||
               normalized != path
      problem("#{what} path #{path} must be relative, inside the workspace and outside audit/") if unsafe
      !unsafe
    end

    def read(path)
      File.read(File.join(@root, path), mode: "rb").force_encoding(Encoding::UTF_8)
    rescue SystemCallError
      nil
    end

    def file_lines(path) = @lines[path] ||= read(path).to_s.lines.map(&:chomp)
    def present?(value) = value.is_a?(String) && !value.strip.empty?

    def time?(value)
      present?(value) && Time.iso8601(value)
    rescue ArgumentError
      false
    end

    def problem(text)
      @problems << text
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  reviewed = ARGV.delete("--reviewed")
  json = ARGV.delete("--json")
  root_index = ARGV.index("--root")
  root = root_index ? ARGV.slice!(root_index, 2).last : Dir.pwd
  path = ARGV.first || "audit/findings.json"
  result = EvidenceAudit::Verifier.new(path, root:, reviewed: !reviewed.nil?).call
  if json
    puts JSON.generate("ok" => result.ok?, "problems" => result.problems)
  elsif result.ok?
    puts "evidence verified: every citation is in its source at its lines, every source is unchanged"
  else
    puts "evidence NOT verified (#{result.problems.length} problem(s)):"
    result.problems.each { |line| puts "- #{line}" }
  end
  exit(result.ok? ? 0 : 1)
end
