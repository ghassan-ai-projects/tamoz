# frozen_string_literal: true

require_relative 'test_helper'

# Slice I (COMMS_TELEGRAM_PLAN §3) — config schema 2 (COMMS_DESIGN §14):
# schema 1 loads unchanged as "no channels", schema 2 is validated strictly
# at load, and `tamoz config migrate` is explicit, backup-preserving, and
# atomic — a refused or crashed migration leaves the original file intact.
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

  # Schema 2 with a strict channels mapping: a bad kind, a missing revision,
  # or a missing expected_bot_id is refused at LOAD, before any command runs.
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
          'expected_bot_id' => 7_463_512_990
        } }
      }

      { 'kind' => 'slack', 'revision' => 0, 'expected_bot_id' => 'abc' }.each do |key, value|
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
      document.fetch('channels').fetch('telegram-ops').delete('expected_bot_id')
      File.write(config_path, Psych.dump(document))
      File.chmod(0o600, config_path)
      error = assert_raises(RuntimeDirectory::Error) do
        RuntimeDirectory.resolve(path: runtime_dir, env: {})
      end
      assert_match(/expected_bot_id is mandatory/, error.message)
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
                                  'expected_bot_id' => 7_463_512_990,
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
