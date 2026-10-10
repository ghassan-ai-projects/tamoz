# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Metrics/BlockLength
class RuntimeDirectoryConfigTest < Minitest::Test
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory

  def with_schema_one_directory
    Dir.mktmpdir('tamoz-config') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      workspace = File.join(directory, 'workspace')
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)
      config_path = File.join(runtime_dir, 'config.yaml')
      File.write(config_path, Psych.dump(
                                'runtime' => { 'schema_version' => 1 },
                                'workspace' => { 'root' => workspace },
                                'sources' => {}
                              ))
      File.chmod(0o600, config_path)
      yield runtime_dir, config_path, workspace
    end
  end

  def cli(argv, env: {})
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(argv, out:, err:, input: StringIO.new, env:)
    [status, out.string, err.string]
  end

  # The schema-1 directory from before channels existed must load unchanged —
  # this is the "schema-1-as-no-channels" reading the design pins.
  def test_a_schema_one_directory_loads_unchanged
    with_schema_one_directory do |runtime_dir, _config_path, _workspace|
      directory = RuntimeDirectory.resolve(path: runtime_dir, env: {})

      assert_equal 2, RuntimeDirectory::SCHEMA_VERSION
      assert_empty directory.channels
      assert_equal 1, directory.config.dig('runtime', 'schema_version')
    end
  end

  def test_config_migrate_bumps_to_schema_two_with_a_backup
    with_schema_one_directory do |runtime_dir, config_path, workspace|
      status, out, err = cli(['--runtime-dir', runtime_dir, 'config', 'migrate'])

      assert_equal 0, status, err
      assert_match(/migrated to schema 2/, out)
      document = Psych.safe_load_file(config_path)

      assert_equal 2, document.dig('runtime', 'schema_version')
      assert_equal workspace, document.dig('workspace', 'root')
      assert_equal({}, document.fetch('channels'))
      backups = Dir.glob("#{config_path}.bak-*")

      assert_equal 1, backups.length, 'migration must preserve a backup of the original'
      backup = Psych.safe_load_file(backups.first)

      assert_equal 1, backup.dig('runtime', 'schema_version'), 'the backup is the original file'
      assert_empty Dir.glob("#{config_path}.tmp-*"), 'no partial-write temp files may remain'
    end
  end

  def test_config_migrate_lands_the_backup_and_the_new_config_through_atomic_file
    with_schema_one_directory do |runtime_dir, config_path, _workspace|
      calls = atomic_writes { cli(['--runtime-dir', runtime_dir, 'config', 'migrate']) }

      backup = Dir.glob("#{config_path}.bak-*").fetch(0)

      assert_equal [[:create, backup, 0o600], [:replace, config_path, 0o600]], calls
    end
  end

  def test_create_publishes_the_default_config_once_through_atomic_file
    Dir.mktmpdir('tamoz-config') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      workspace = File.join(directory, 'workspace')
      FileUtils.mkdir_p(workspace)

      calls = atomic_writes { RuntimeDirectory.create!(runtime_dir, workspace:) }
      config_path = File.join(runtime_dir, 'config.yaml')
      before = File.read(config_path)
      again = atomic_writes { RuntimeDirectory.create!(runtime_dir, workspace: File.join(directory, 'other')) }

      assert_equal [[:create, config_path, 0o600]], calls
      assert_empty again
      assert_equal before, File.read(config_path)
    end
  end

  def test_config_migrate_is_idempotent_and_never_writes_twice
    with_schema_one_directory do |runtime_dir, config_path, _workspace|
      status, = cli(['--runtime-dir', runtime_dir, 'config', 'migrate'])

      assert_equal 0, status
      before = File.read(config_path)

      status, out, err = cli(['--runtime-dir', runtime_dir, 'config', 'migrate'])

      assert_equal 0, status, err
      assert_match(/already schema 2/, out)
      assert_equal before, File.read(config_path)
      assert_equal 1, Dir.glob("#{config_path}.bak-*").length
    end
  end

  # A migration that cannot succeed must refuse BEFORE anything is written:
  # no backup, no temp file, original bytes untouched.
  def test_config_migrate_refuses_an_invalid_document_without_writing
    with_schema_one_directory do |runtime_dir, config_path, _workspace|
      File.write(config_path, Psych.dump('runtime' => { 'schema_version' => 1 }))
      File.chmod(0o600, config_path)
      original = File.read(config_path)

      status, _out, err = cli(['--runtime-dir', runtime_dir, 'config', 'migrate'])

      assert_equal 1, status
      assert_match(/must set workspace\.root/, err)
      assert_equal original, File.read(config_path), 'a refused migration must not touch the original'
      assert_empty Dir.glob("#{config_path}.bak-*")
      assert_empty Dir.glob("#{config_path}.tmp-*")
    end
  end

  # A key the config no longer has fails by name and says how to rebuild the channels; nothing reads it.
  def test_a_removed_channel_key_is_refused_by_name
    Dir.mktmpdir('tamoz-runtime-config') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      path = RuntimeDirectory.create!(File.join(root, 'runtime'), workspace:).path
      config = File.join(path, RuntimeDirectory::CONFIG_FILE)
      entry = { 'kind' => 'telegram', 'revision' => 1, 'enabled' => true, 'profile' => 'chat',
                'stream_id' => 'telegram:bot:7', 'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' } }
      { 'expected_bot_id' => 7, 'talk' => { 'port' => 8787 } }.each do |key, value|
        File.write(config, Psych.dump(Psych.safe_load_file(config).merge('channels' => { 'ops' => entry.merge(key => value) })))

        error = assert_raises(RuntimeDirectory::Error) { RuntimeDirectory.resolve(path:, env: {}).channels }
        assert_includes error.message, "channels.ops.#{key} is not a channel field"
        assert_includes error.message, '`tamoz channel add`'
      end
    end
  end

  # A surface id names a folder under the runtime, so it can never climb out of it.
  def test_a_surface_id_is_a_plain_name
    Dir.mktmpdir('tamoz-runtime-config') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      path = RuntimeDirectory.create!(File.join(root, 'runtime'), workspace:).path
      config = File.join(path, RuntimeDirectory::CONFIG_FILE)
      entry = { 'kind' => 'telegram', 'revision' => 1, 'enabled' => true, 'profile' => 'chat', 'stream_id' => 'telegram:bot:7',
                'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' } }
      ['../..', 'Telegram', 'a/b', ''].each do |surface|
        File.write(config, Psych.dump(Psych.safe_load_file(config).merge('channels' => { surface => entry })))

        assert_raises(RuntimeDirectory::Error, surface) { RuntimeDirectory.resolve(path:, env: {}).channels }
      end
    end
  end

  # Schema 2 with a strict channels mapping: a bad kind, a missing revision,
  # or a missing stream_id is refused at LOAD, before any command runs.
  def test_schema_two_validates_channels_strictly
    Dir.mktmpdir('tamoz-config') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)
      config_path = File.join(runtime_dir, 'config.yaml')
      base = {
        'runtime' => { 'schema_version' => 2 },
        'workspace' => { 'root' => directory },
        'sources' => {},
        'channels' => { 'telegram-ops' => {
          'kind' => 'telegram', 'revision' => 1, 'enabled' => true,
          'profile' => 'ops', 'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
          'stream_id' => 'telegram:bot:7463512990'
        } }
      }

      { 'kind' => 'Slack', 'revision' => 0, 'stream_id' => 7 }.each do |key, value|
        document = deep_dup(base)
        document.fetch('channels').fetch('telegram-ops')[key] = value
        File.write(config_path, Psych.dump(document))
        File.chmod(0o600, config_path)

        error = assert_raises(RuntimeDirectory::Error) do
          RuntimeDirectory.resolve(path: runtime_dir, env: {})
        end
        assert_match(/channels\.telegram-ops\.#{key}/, error.message)
      end

      document = deep_dup(base)
      document.fetch('channels').fetch('telegram-ops').delete('stream_id')
      File.write(config_path, Psych.dump(document))
      File.chmod(0o600, config_path)
      error = assert_raises(RuntimeDirectory::Error) do
        RuntimeDirectory.resolve(path: runtime_dir, env: {})
      end
      assert_match(/stream_id is mandatory/, error.message)
    end
  end

  def test_a_valid_schema_two_channels_mapping_loads
    Dir.mktmpdir('tamoz-config') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)
      config_path = File.join(runtime_dir, 'config.yaml')
      File.write(config_path, Psych.dump(
                                'runtime' => { 'schema_version' => 2 },
                                'workspace' => { 'root' => directory },
                                'sources' => {},
                                'channels' => { 'telegram-ops' => {
                                  'kind' => 'telegram', 'revision' => 2, 'enabled' => true,
                                  'profile' => 'ops',
                                  'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                                  'stream_id' => 'telegram:bot:7463512990',
                                  'admission' => {
                                    'direct' => 'allowlist',
                                    'correspondents' => ['telegram:user:11111111']
                                  }
                                } }
                              ))
      File.chmod(0o600, config_path)

      directory = RuntimeDirectory.resolve(path: runtime_dir, env: {})

      entry = directory.channels.fetch('telegram-ops')

      assert_equal 'telegram', entry.fetch('kind')
      assert_equal 2, entry.fetch('revision')
      assert_equal 'allowlist', entry.dig('admission', 'direct')
    end
  end

  private

  def deep_dup(value)
    case value
    when Hash then value.to_h { |key, entry| [key, deep_dup(entry)] }
    when Array then value.map { |entry| deep_dup(entry) }
    else value
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:enable Metrics/BlockLength
