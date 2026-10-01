# frozen_string_literal: true

require_relative 'test_helper'

# QUALITY_BAR O1, O3: the operator sees every skill and every rejection, and `check` fails on any issue.
class CliSkillsCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('tamoz-cli-skills')
    @workspace = File.join(@dir, 'ws')
    @skills = File.join(@dir, 'skills')
    FileUtils.mkdir_p([@workspace, File.join(@skills, 'thin'), File.join(@skills, 'broken')])
    File.write(File.join(@skills, 'thin', 'SKILL.md'), "---\nname: thin\ndescription: Does a thing.\n---\nBody\n")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def tamoz(*args)
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--root', @workspace, *args], out:, err:, env: {})
    [status, out.string, err.string]
  end

  def test_list_shows_skills_digests_and_rejections
    status, out, = tamoz('--skills', @skills, '--bundled-skills', 'skills', 'list')

    assert_equal 0, status
    assert_match(%r{bundled/evidence-audit \[bundled\] sha256:\h{64}}, out)
    assert_includes out, 'operator/thin [operator]'
    assert_includes out, 'rejected operator/broken: skill_manifest_missing'
  end

  def test_check_fails_on_a_skill_below_the_bar_and_passes_on_the_bundled_ones
    failing, out, = tamoz('--skills', @skills, 'skills', 'check')
    passing, = tamoz('--bundled-skills', 'skills', 'check')

    assert_equal 1, failing
    assert_includes out, 'operator/thin Q1: the description does not say when'
    assert_equal 0, passing
  end

  def test_path_prints_the_skill_directory
    status, out, = tamoz('--bundled-skills', 'skills', 'path', 'evidence-audit')

    assert_equal 0, status
    assert_equal File.join(Tamoz::Skills.bundled_root, 'evidence-audit'), out.strip
  end

def test_an_operator_skills_root_inside_the_workspace_is_refused_for_a_session
  inside = File.join(@workspace, 'skills')
  FileUtils.mkdir_p(inside)
  sessions = File.join(@dir, 'sessions')
  FileUtils.mkdir_p(sessions, mode: 0o700)
  err = StringIO.new
  status = Tamoz::Agent::CLI.run(['--root', @workspace, '--session-dir', sessions, '--skills', inside, '--allow-changes',
                                  'code', 'task'], out: StringIO.new, err:,
                                 env: { 'TAMOZ_PROVIDER' => 'deepseek', 'TAMOZ_MODEL' => 'deepseek-chat', 'DEEPSEEK_API_KEY' => 'unused' })

  refute_equal 0, status
  assert_match(/overlaps the workspace/, err.string)
  assert_equal 0, tamoz('--skills', inside, 'skills', 'list').first, 'a read-only view is not a session'
end

  def test_an_invoked_skill_must_load_before_the_first_model_call
    sessions = File.join(@dir, "sessions")
    FileUtils.mkdir_p(sessions, mode: 0o700)
    env = { "TAMOZ_PROVIDER" => "deepseek", "TAMOZ_MODEL" => "deepseek-chat", "DEEPSEEK_API_KEY" => "unused" }
    run = lambda do |*flags|
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(["--root", @workspace, "--session-dir", sessions, "--allow-changes", *flags,
                                      "code", "task"], out: StringIO.new, err:, env:)
      [status, err.string]
    end

    refute_equal 0, run.call("--skill", "evidence-audit").first
    assert_match(/needs --skills DIR or --bundled-skills/, run.call("--skill", "evidence-audit").last)
    assert_match(/skill_unknown/, run.call("--bundled-skills", "--skill", "nope").last)
  end

  def test_new_show_and_promote_author_a_skill_through_a_named_person
    drafts = File.join(@dir, 'drafts')
    FileUtils.mkdir_p(drafts)
    installed = File.join(@dir, 'installed')
    FileUtils.mkdir_p(installed)
    status, out, = tamoz('skills', 'new', 'tidy-notes', '--dir', drafts)
    directory = out.strip

    assert_equal 0, status
    Tamoz::Skills.stage_candidate(directory, created_by: 'tamoz.skill-creator', source: 'test')
    refused, = tamoz('--skills', installed, 'skills', 'promote', directory, '--approver', 'tamoz.skill-creator')
    promoted, promote_out, = tamoz('--skills', installed, 'skills', 'promote', directory, '--approver', 'dana')
    shown, show_out, = tamoz('--skills', installed, 'skills', 'show', 'tidy-notes')

    refute_equal 0, refused
    assert_equal 0, promoted
    assert_match(/installed tidy-notes sha256:\h{64}, approved by dana/, promote_out)
    assert_equal 0, shown
    assert_includes show_out, 'authoring bar: met'
  end

  def test_create_refuses_a_thread_that_did_not_finish_verified
    sessions = File.join(@dir, 'sessions')
    FileUtils.mkdir_p(sessions, mode: 0o700)
    status, _, err = tamoz('--session-dir', sessions, 'skills', 'create', 'x', '--from-session', 'missing')

    refute_equal 0, status
    refute_empty err
  end
end
