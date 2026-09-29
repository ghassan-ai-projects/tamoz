# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize

require_relative 'test_helper'
require_relative 'support/memory_spec'

# Memory::Access is the one place that decides what an owner in a workspace can see, list,
# and delete; every caller outside the memory gem goes through it.
class MemoryAccessTest < Minitest::Test
  include MemorySpec

  DAY = 86_400

  def setup
    @directory = Dir.mktmpdir('tamoz-memory-access')
    @workspace = File.join(@directory, 'workspace')
    FileUtils.mkdir_p(@workspace)
    @now = Time.at(1_800_000_000)
    @engine, @adapter = memory_engine_at(@directory, clock: -> { @now })
    @access = @engine.access(owner: 'alice', workspace: @workspace)
  end

  def teardown
    @adapter&.close
    FileUtils.remove_entry(@directory)
  end

  def fact(statement, user: 'alice', project: @access.project, sensitivity: :internal)
    owner_fact(@engine, statement, user:, project:, sensitivity:)
  end

  def test_find_sees_only_this_owner_and_workspace_while_eligible
    mine = fact('lint runs before every push')
    theirs = fact('bob runs lint after every push', user: 'bob')
    elsewhere = fact('the other repo lints on save', project: 'ws:elsewhere')
    secret = fact('the lint token lives in the vault', sensitivity: :sensitive)
    @engine.lifecycle.delete(memory_id: fact('lint once a day').memory_id)

    assert_equal mine.memory_id, @access.find(mine.memory_id)&.memory_id
    assert_nil(@access.find(theirs.memory_id) || @access.find(elsewhere.memory_id) || @access.find(secret.memory_id))
    assert_equal [mine.memory_id], @access.list('lint').map(&:memory_id)
  end

  def test_expired_experience_is_invisible_and_delete_stays_in_scope
    episode = @access.record_experience(session: 's1', task: 'rotate the signing key', plan_digest: 'sha256:x',
                                        statement: 'Task: rotate the signing key | Outcome: done', outcome: 'done')
    elsewhere = fact('the other repo keeps keys in kms', project: 'ws:elsewhere')

    assert_equal episode.record.memory_id, @access.find(episode.record.memory_id)&.memory_id
    assert_nil @access.delete(elsewhere.memory_id)
    @now += 91 * DAY

    assert_nil @access.find(episode.record.memory_id)
  end
end
# rubocop:enable Metrics/AbcSize
