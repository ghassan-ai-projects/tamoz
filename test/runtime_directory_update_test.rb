# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# An operator edit to a runtime's config: validated whole, backed up, written atomically; one chat profile per runtime.
class RuntimeDirectoryUpdateTest < Minitest::Test
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory
  CHAT = { 'chat' => { 'provider' => 'zai', 'model' => 'glm-5.3-flash' } }.freeze

  def with_runtime
    Dir.mktmpdir('tamoz-update') do |root|
      workspace = File.join(root, 'workspace')
      FileUtils.mkdir_p(workspace)
      yield RuntimeDirectory.create!(File.join(root, 'runtime'), workspace:).path
    end
  end

  def configure(path, models) = RuntimeDirectory.configure!(path, workspace: nil, models:, env: {})

  def config_path(path) = File.join(path, RuntimeDirectory::CONFIG_FILE)

  def backups(path) = Dir["#{config_path(path)}.bak-*"]

  def channel(profile)
    { 'kind' => 'talk', 'revision' => 1, 'enabled' => true, 'profile' => profile,
      'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TALK_TOKEN' },
      'expected_bot_id' => 123_456_789_012, 'talk' => { 'port' => 8787 } }
  end

  def test_an_edit_is_written_with_a_backup_of_the_old_file
    with_runtime do |path|
      directory = configure(path, CHAT)

      assert_equal 'glm-5.3-flash', directory.models['chat'].model
      assert_equal 1, backups(path).length
      refute_includes File.read(backups(path).first), 'glm-5.3-flash'
    end
  end

  def test_edits_in_quick_succession_each_keep_their_own_backup
    with_runtime do |path|
      %w[glm-4.6 glm-5.3-flash].each { |model| configure(path, 'chat' => { 'provider' => 'zai', 'model' => model }) }

      assert_equal 2, backups(path).length
    end
  end

  def test_an_edit_that_changes_nothing_writes_nothing
    with_runtime do |path|
      configure(path, {})

      assert_empty backups(path)
    end
  end

  def test_an_edit_that_would_not_load_is_refused_before_anything_is_written
    with_runtime do |path|
      before = File.read(config_path(path))
      assert_raises(RuntimeDirectory::Error) { configure(path, 'chat' => { 'provider' => 'zai' }) }

      assert_equal before, File.read(config_path(path))
      assert_empty backups(path)
    end
  end

  def test_every_channel_names_the_same_profile
    with_runtime do |path|
      document = Psych.safe_load_file(config_path(path))
      File.write(config_path(path), Psych.dump(document.merge('channels' => { 'talk' => channel('chat'),
                                                                              'talk2' => channel('other') })))
      error = assert_raises(RuntimeDirectory::Error) { RuntimeDirectory.resolve(path:, env: {}) }

      assert_match(/one profile/, error.message)
    end
  end
end
