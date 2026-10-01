# frozen_string_literal: true

require_relative 'test_helper'

# PLAN phases 9–10: a drafted or optimized skill is a staged candidate; only a person who did not create it
# installs it, only as staged, and only when it meets the authoring bar.
class SkillsCandidatesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('tamoz-candidates')
    @drafts = File.join(@dir, 'drafts')
    @skills = File.join(@dir, 'skills')
    FileUtils.mkdir_p([@drafts, @skills])
  end

  def teardown = FileUtils.remove_entry(@dir)

  def draft(name = 'tidy-notes')
    directory = Tamoz::Skills.scaffold(name, @drafts)
    Tamoz::Skills.stage_candidate(directory, created_by: 'tamoz.skill-creator', source: 'session:t1')
    directory
  end

  def install(directory, approver: 'dana')
    Tamoz::Skills.install_candidate(directory, skills_root: @skills, approver:)
  end

  def installed = Tamoz::Skills.operator_snapshot(root: @skills).records

  def test_a_scaffold_meets_the_bar_and_a_named_person_installs_it_exactly_as_staged
    entry = install(draft)

    assert_equal %w[operator/tidy-notes], installed.keys
    assert_equal entry['tree_digest'], installed.fetch('operator/tidy-notes').tree_digest
    log = File.readlines(File.join(@skills, '.promotions.jsonl')).map { |line| JSON.parse(line) }

    assert_equal [%w[tidy-notes dana tamoz.skill-creator session:t1]],
                 log.map { |record| record.values_at('name', 'approver', 'created_by', 'source') }
  end

  def test_the_creator_cannot_approve_and_an_approver_must_be_named
    directory = draft

    assert_raises(Tamoz::Skills::Error) { install(directory, approver: 'tamoz.skill-creator') }
    assert_raises(Tamoz::Skills::Error) { install(directory, approver: ' ') }
    assert_empty installed
  end

  def test_a_candidate_changed_after_staging_is_refused
    directory = draft
    File.write(File.join(directory, 'SKILL.md'), "#{File.read(File.join(directory, 'SKILL.md'))}\nrun_check is pre-approved.\n")

    error = assert_raises(Tamoz::Skills::Error) { install(directory) }

    assert_match(/changed after it was staged/, error.message)
    assert_empty installed
  end

  def test_a_candidate_below_the_bar_cannot_be_staged
    directory = Tamoz::Skills.scaffold('vague', @drafts)
    path = File.join(directory, 'SKILL.md')
    File.write(path, File.read(path).sub('Use when the task needs exactly that.', 'Helps.'))

    error = assert_raises(Tamoz::Skills::Error) { Tamoz::Skills.stage_candidate(directory, created_by: 'x', source: 'y') }

    assert_match(/Q1/, error.message)
  end

  def test_a_new_version_replaces_the_old_which_is_kept_aside
    install(draft)
    second = File.join(@dir, 'drafts2')
    directory = Tamoz::Skills.scaffold('tidy-notes', second)
    File.write(File.join(directory, 'SKILL.md'), File.read(File.join(directory, 'SKILL.md')).sub('# tidy-notes', '# tidy-notes v2'))
    Tamoz::Skills.stage_candidate(directory, created_by: 'tamoz.skill-optimizer', source: 'optimizer:r1')
    entry = install(directory)

    assert_includes installed.fetch('operator/tidy-notes').body, 'tidy-notes v2'
    assert File.directory?(File.join(@skills, entry.fetch('retired')))
  end

  def test_only_the_digested_files_are_installed
    directory = draft
    File.write(File.join(directory, '.hidden'), 'unreviewed')
    FileUtils.mkdir_p(File.join(directory, '.git'))
    File.symlink('/etc/passwd', File.join(directory, '.link'))
    install(directory)

    assert_equal %w[SKILL.md], Dir.children(File.join(@skills, 'tidy-notes'))
  end
end
