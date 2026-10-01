# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../gems/tamoz-skills/skills/evidence-audit/scripts/verify_findings'

# QUALITY_BAR E1–E3, E5, E6, E9: the verifier accepts a faithful findings file, and each rule has a failing twin.
class SkillsEvidenceVerifierTest < Minitest::Test
  POLICY = <<~TEXT
    # Access policy

    ## 2. Passwords

    Passwords must contain at least 8 characters
    and must be rotated every 180 days.

    ## 3. Reviews

    Access is reviewed once a year by the system owner.
    Reviews are recorded in the access register.
    The register is kept for two years.
    Exceptions need written approval.
  TEXT

  def setup
    @root = Dir.mktmpdir('tamoz-audit')
    File.write(File.join(@root, 'policy.md'), POLICY)
    File.write(File.join(@root, 'criteria.md'), "C1: Passwords must be at least 12 characters.\n")
    FileUtils.mkdir_p(File.join(@root, 'audit'))
  end

  def teardown = FileUtils.remove_entry(@root)

  def finding(**overrides)
    { 'id' => 'F-001', 'criterion' => 'C1', 'title' => 'Minimum length is 8', 'conclusion' => 'exception',
      'severity' => 'high', 'statement' => 'The minimum is 8, below 12.', 'reasoning' => 'Section 2 states it.',
      'evidence' => [{ 'path' => 'policy.md', 'lines' => [5, 5],
                       'quote' => 'Passwords must contain at least 8 characters', 'supports' => 'The minimum.' }],
      'review' => { 'status' => 'proposed', 'reviewer' => nil, 'decided_at' => nil, 'note' => nil } }.merge(overrides)
  end

  def verify(findings: [finding], sha: Digest::SHA256.hexdigest(POLICY), report: "F-001 pending review\n", **options)
    document = { 'audit' => { 'title' => 'Access', 'criteria_source' => 'criteria.md' },
                 'sources' => [{ 'path' => 'policy.md', 'sha256' => sha }],
                 'criteria' => [{ 'id' => 'C1', 'text' => 'Passwords must be at least 12 characters.' }],
                 'findings' => findings }
    File.write(File.join(@root, 'audit', 'findings.json'), JSON.generate(document))
    File.write(File.join(@root, 'audit', 'REPORT.md'), report) if report
    EvidenceAudit::Verifier.new('audit/findings.json', root: @root, **options).call
  end

  def assert_problem(pattern, result) = assert(result.problems.any? { |line| line.match?(pattern) }, result.problems)

  def cite(**overrides) = finding('evidence' => [finding['evidence'].first.merge(overrides)])

  def test_a_faithful_findings_file_verifies
    assert_empty verify.problems
  end

  def test_a_quote_spanning_two_lines_verifies_with_whitespace_collapsed
    two = cite('lines' => [5, 6], 'quote' => "at least 8 characters\n  and must be rotated every 180 days")

    assert_empty verify(findings: [two]).problems
  end

  def test_a_fabricated_quote_fails
    assert_problem(/not in the file verbatim/, verify(findings: [cite('quote' => 'Passwords must contain at least 12 characters')]))
  end

  def test_a_misplaced_quote_fails_and_says_where_it_is
    assert_problem(/lines 3-3; it is at lines 5-5/, verify(findings: [cite('lines' => [3, 3])]))
  end

  def test_a_broad_citation_or_a_short_quote_fails
    assert_problem(/at most 10 lines/, verify(findings: [cite('lines' => [1, 11])]))
    assert_problem(/at least 20 characters/, verify(findings: [cite('quote' => 'at least 8')]))
  end

  def test_a_changed_source_fails
    assert_problem(/source policy.md changed/, verify(sha: 'a' * 64))
  end

  def test_a_citation_of_an_unlisted_file_fails
    assert_problem(/not a listed source/, verify(findings: [cite('path' => 'criteria.md')]))
  end

  def test_a_self_approved_finding_fails_while_preparing
    approved = finding('review' => { 'status' => 'accepted', 'reviewer' => 'tamoz', 'decided_at' => nil })

    assert_problem(/only a person decides it/, verify(findings: [approved]))
  end

  def test_an_uncovered_criterion_fails
    assert_problem(/criterion C1 has no finding/, verify(findings: [finding('criterion' => 'C9')]))
  end

  def test_the_report_must_cite_every_finding_and_invent_none
    assert_problem(/REPORT.md does not mention F-001/, verify(report: "Nothing here\n"))
    assert_problem(/mentions F-002, which is not a finding/, verify(report: "F-001 and F-002\n"))
  end

  def test_a_missing_report_fails
    assert_problem(/REPORT.md is missing/, verify(report: nil))
  end

  def test_a_reviewed_decision_names_its_reviewer_and_time
    decided = finding('review' => { 'status' => 'accepted', 'reviewer' => 'Dana Auditor',
                                    'decided_at' => '2026-10-01T12:00:00Z', 'note' => nil })
    unnamed = finding('review' => { 'status' => 'rejected', 'reviewer' => nil, 'decided_at' => nil })

    assert_empty verify(findings: [decided], reviewed: true).problems
    assert_problem(/names its reviewer and decided_at/, verify(findings: [unnamed], reviewed: true))
  end

  def test_no_exception_is_always_info
    assert_problem(/no_exception finding has severity info/,
                   verify(findings: [finding('conclusion' => 'no_exception', 'severity' => 'high')]))
  end

  def test_conflicting_conclusions_on_one_criterion_fail
    twin = finding("id" => "F-002", "conclusion" => "no_exception", "severity" => "info")

    assert_problem(/C1 has conflicting conclusions/, verify(findings: [finding, twin], report: "F-001 F-002\n"))
  end

  def test_more_than_three_citations_fail
    carpet = finding("evidence" => Array.new(4) { finding["evidence"].first })

    assert_problem(/at most 3 passages in evidence/, verify(findings: [carpet]))
  end

  def test_a_source_path_that_resolves_into_audit_is_refused
    File.write(File.join(@root, "audit", "notes.md"), "Passwords must contain at least 8 characters\n")
    document = { "path" => "./audit/notes.md", "sha256" => "x" }
    result = verify.tap { }
    json = JSON.parse(File.read(File.join(@root, "audit", "findings.json")))
    json["sources"] << document.merge("sha256" => Digest::SHA256.hexdigest(File.read(File.join(@root, "audit", "notes.md"))))
    File.write(File.join(@root, "audit", "findings.json"), JSON.generate(json))

    assert_empty result.problems
    assert_problem(/must be relative, inside the workspace and outside audit/,
                   EvidenceAudit::Verifier.new("audit/findings.json", root: @root).call)
  end
end
