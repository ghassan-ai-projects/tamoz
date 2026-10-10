# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Metrics/BlockLength
class RuntimeDirectoryConfigTest < Minitest::Test
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory

  def cli(argv, env: {})
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(argv, out:, err:, input: StringIO.new, env:)
    [status, out.string, err.string]
  end

  def test_only_the_current_schema_loads
    Dir.mktmpdir('tamoz-config') do |directory|
      path = RuntimeDirectory.create!(File.join(directory, 'runtime'), workspace: directory).path
      config = File.join(path, RuntimeDirectory::CONFIG_FILE)
      File.write(config, Psych.dump(Psych.safe_load_file(config).merge('runtime' => { 'schema_version' => 1 })))

      error = assert_raises(RuntimeDirectory::Error) { RuntimeDirectory.resolve(path:, env: {}) }
      assert_includes error.message, 'schema_version 1 is not supported (expected 2)'
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

  # A key the config no longer has fails by name and says how to rebuild the channels; nothing reads it.
  def test_a_removed_channel_key_is_refused_by_name
    Dir.mktmpdir('tamoz-runtime-config') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      path = RuntimeDirectory.create!(File.join(root, 'runtime'), workspace:).path
      config = File.join(path, RuntimeDirectory::CONFIG_FILE)
      entry = { 'kind' => 'telegram', 'revision' => 1, 'enabled' => true, 'profile' => 'chat',
                'stream_id' => 'telegram:bot:7', 'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN' } }
      { 'expected_bot_id' => 7, 'talk' => { 'port' => 8787 } }.each do |key, value|
        File.write(config,
                   Psych.dump(Psych.safe_load_file(config).merge('channels' => { 'ops' => entry.merge(key => value) })))

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
