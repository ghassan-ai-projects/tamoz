# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# `tamoz setup` makes or updates a runtime: its workspace, its models and its one chat profile.
class CLISetupTest < Minitest::Test
  RuntimeDirectory = Tamoz::Agent::RuntimeDirectory
  SPEECH = %w[--transcription openrouter/openai/gpt-4o-mini-transcribe
              --transcription-credential OPENROUTER_SPEECH_API_KEY].freeze
  TALK = { 'kind' => 'talk', 'revision' => 1, 'enabled' => true, 'profile' => 'telegram',
           'credential_ref' => { 'kind' => 'env', 'name' => 'TAMOZ_TALK_TOKEN' },
           'expected_bot_id' => 123_456_789_012, 'talk' => { 'port' => 8787 } }.freeze

  def with_dirs
    Dir.mktmpdir('tamoz-setup') do |root|
      workspace = File.join(root, 'workspace')
      FileUtils.mkdir_p(workspace)
      yield File.join(root, 'runtime'), workspace
    end
  end

  def tamoz(*argv, env: {})
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(argv, out:, err:, input: StringIO.new, env:)
    [status, out.string, err.string]
  end

  def setup_cli(runtime, *, env: {}) = tamoz('--runtime-dir', runtime, 'setup', *, env:)

  def config_path(runtime) = File.join(runtime, RuntimeDirectory::CONFIG_FILE)

  def config(runtime) = Psych.safe_load_file(config_path(runtime))

  def backups(runtime) = Dir["#{config_path(runtime)}.bak-*"]

  def runtime_with_talk_channel(runtime, workspace)
    RuntimeDirectory.create!(runtime, workspace:)
    File.write(config_path(runtime), Psych.dump(config(runtime).merge('channels' => { 'talk' => TALK })))
  end

  def test_setup_creates_a_runtime_with_its_models
    with_dirs do |runtime, workspace|
      status, = setup_cli(runtime, '--workspace', workspace, '--chat', 'zai/glm-5.3-flash', *SPEECH)
      models = RuntimeDirectory.resolve(path: runtime, env: {}).models

      assert_equal [0, %w[zai glm-5.3-flash], %w[openrouter openai/gpt-4o-mini-transcribe]],
                   [status, [models['chat'].provider, models['chat'].model],
                    [models['transcription'].provider, models['transcription'].model]]
    end
  end

  def test_setup_writes_one_private_chat_profile
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace)

      assert_equal 0o600, File.stat(File.join(runtime, 'profiles', 'chat.yaml')).mode & 0o777
    end
  end

  def test_the_chat_profile_offers_the_skill_tools_when_skills_are_enabled
    with_dirs do |runtime, workspace|
      RuntimeDirectory.create!(runtime, workspace:)
      File.write(config_path(runtime),
                 Psych.dump(config(runtime).merge('sources' => { 'skills' => { 'enabled' => true } })))
      FileUtils.mkdir_p(File.join(runtime, 'skills'))
      FileUtils.cp_r(File.join(Tamoz::Skills.bundled_root, 'evidence-audit'), File.join(runtime, 'skills'))
      setup_cli(runtime)

      assert_includes Psych.safe_load_file(File.join(runtime, 'profiles', 'chat.yaml')).dig('tools', 'allowed'),
                      'load_skill'
    end
  end

  def test_a_new_runtime_works_in_the_root_unless_a_workspace_is_named
    with_dirs do |runtime, workspace|
      status, = tamoz('--runtime-dir', runtime, '--root', workspace, 'setup')

      assert_equal [0, File.realpath(workspace)],
                   [status, File.realpath(RuntimeDirectory.resolve(path: runtime, env: {}).workspace_root)]
    end
  end

  def test_a_workspace_that_is_not_a_directory_leaves_no_runtime_behind
    with_dirs do |runtime, workspace|
      status, = setup_cli(runtime, '--workspace', File.join(workspace, 'missing'))

      assert_equal 1, status
      refute_path_exists runtime
    end
  end

  def test_a_rerun_changes_only_what_it_names
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace, '--chat', 'zai/glm-5.3-flash')
      setup_cli(runtime, '--vision', 'openrouter/openai/gpt-4o-mini', '--vision-credential',
                'OPENROUTER_SPEECH_API_KEY')

      assert_equal({ 'chat' => { 'provider' => 'zai', 'model' => 'glm-5.3-flash' },
                     'vision' => { 'provider' => 'openrouter', 'model' => 'openai/gpt-4o-mini',
                                   'credential' => 'OPENROUTER_SPEECH_API_KEY' } },
                   config(runtime).fetch('models'))
    end
  end

  def test_a_rerun_naming_one_field_keeps_the_others_of_that_role
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace, *SPEECH)
      setup_cli(runtime, '--transcription-api-base', 'https://speech.example/v1')

      assert_equal({ 'provider' => 'openrouter', 'model' => 'openai/gpt-4o-mini-transcribe',
                     'credential' => 'OPENROUTER_SPEECH_API_KEY', 'api_base' => 'https://speech.example/v1' },
                   config(runtime).dig('models', 'transcription'))
    end
  end

  def test_a_role_moved_to_another_provider_drops_the_old_key_and_endpoint
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace, *SPEECH, '--transcription-api-base', 'https://speech.example/v1')
      setup_cli(runtime, '--transcription', 'openai/whisper-1')

      assert_equal({ 'provider' => 'openai', 'model' => 'whisper-1' }, config(runtime).dig('models', 'transcription'))
    end
  end

  def test_a_rerun_that_changes_nothing_writes_nothing
    with_dirs do |runtime, workspace|
      2.times { setup_cli(runtime, '--workspace', workspace, '--chat', 'zai/glm-5.3-flash') }

      assert_empty backups(runtime)
    end
  end

  def test_a_bad_model_is_refused_without_echoing_it_and_the_config_is_untouched
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace, '--chat', 'zai/glm-5.3-flash')
      before = File.read(config_path(runtime))
      key = 'sk-or-v1-0123456789abcdef0123456789abcdef'
      status, _out, err = setup_cli(runtime, '--transcription', 'openrouter/x/y', '--transcription-credential', key)

      assert_equal [1, before], [status, File.read(config_path(runtime))]
      refute_includes err, key
    end
  end

  def test_a_bad_model_on_a_first_run_leaves_no_runtime_behind
    with_dirs do |runtime, workspace|
      status, = setup_cli(runtime, '--workspace', workspace, '--vision', 'openrouter/x/y', '--vision-credential',
                          'nope')

      assert_equal 1, status
      refute_path_exists runtime
    end
  end

  def test_a_model_is_named_as_provider_slash_model
    with_dirs do |runtime, workspace|
      status, _out, err = setup_cli(runtime, '--workspace', workspace, '--chat', 'glm-5.3-flash')

      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
      assert_match(%r{--chat takes PROVIDER/MODEL}, err)
    end
  end

  def test_a_missing_key_is_reported_by_name_not_refused
    with_dirs do |runtime, workspace|
      status, out, = setup_cli(runtime, '--workspace', workspace, '--chat', 'zai/glm-5.3-flash', *SPEECH,
                               env: { 'ZAI_API_KEY' => 'k' })

      assert_equal 0, status
      assert_includes out, 'OPENROUTER_SPEECH_API_KEY is not set'
      refute_includes out, 'ZAI_API_KEY is not set'
    end
  end

  def test_json_reports_the_runtime_and_its_missing_keys
    with_dirs do |runtime, workspace|
      _status, out, = setup_cli(runtime, '--workspace', workspace, '--chat', 'zai/glm-5.3-flash', '--json')

      assert_equal({ 'models' => { 'chat' => 'zai/glm-5.3-flash' }, 'chat_profile' => 'chat',
                     'missing_keys' => ['ZAI_API_KEY'] },
                   JSON.parse(out).slice('models', 'chat_profile', 'missing_keys'))
    end
  end

  def test_the_profile_the_channels_name_is_the_one_written
    with_dirs do |runtime, workspace|
      runtime_with_talk_channel(runtime, workspace)
      setup_cli(runtime)

      assert_equal ['telegram.yaml'], Dir.children(File.join(runtime, 'profiles'))
    end
  end

  def test_an_existing_chat_profile_is_never_rewritten
    with_dirs do |runtime, workspace|
      runtime_with_talk_channel(runtime, workspace)
      setup_cli(runtime)
      profile = File.join(runtime, 'profiles', 'telegram.yaml')
      File.write(profile, before = "#{File.read(profile)}# the operator's edit\n")
      status, = setup_cli(runtime, '--chat', 'zai/glm-5.3-flash')

      assert_equal [0, before], [status, File.read(profile)]
    end
  end

  def test_a_runtime_without_a_profile_moves_to_another_workspace
    with_dirs do |runtime, workspace|
      RuntimeDirectory.create!(runtime, workspace: File.dirname(workspace))
      status, = setup_cli(runtime, '--workspace', workspace)

      assert_equal [0, workspace], [status, config(runtime).dig('workspace', 'root')]
    end
  end

  def test_a_move_to_a_workspace_that_is_not_a_directory_changes_nothing
    with_dirs do |runtime, workspace|
      RuntimeDirectory.create!(runtime, workspace:)
      before = File.read(config_path(runtime))
      status, = setup_cli(runtime, '--workspace', File.join(workspace, 'missing'))

      assert_equal [1, before, []], [status, File.read(config_path(runtime)), backups(runtime)]
    end
  end

  def test_the_workspace_of_a_runtime_with_a_profile_cannot_move
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace)
      before = File.read(config_path(runtime))
      status, _out, err = setup_cli(runtime, '--workspace', File.dirname(workspace), '--chat', 'zai/glm-5.3-flash')

      assert_equal [1, before, []], [status, File.read(config_path(runtime)), backups(runtime)]
      assert_match(/workspace .* cannot change/, err)
    end
  end

  def test_the_same_workspace_through_a_link_is_not_a_move
    with_dirs do |runtime, workspace|
      setup_cli(runtime, '--workspace', workspace)
      File.symlink(workspace, link = "#{workspace}-link")
      status, = setup_cli(runtime, '--workspace', link)

      assert_equal 0, status
    end
  end

  def test_help_lists_the_options_and_succeeds
    with_dirs do |runtime, _workspace|
      status, out, = setup_cli(runtime, '--help')

      assert_equal 0, status
      assert_includes out, '--transcription-credential NAME'
      refute_path_exists runtime
    end
  end

  def test_init_is_gone
    with_dirs do |runtime, workspace|
      status, = tamoz('--runtime-dir', runtime, 'init', '--workspace', workspace)

      refute_includes Tamoz::Agent::CLI::SUBCOMMANDS, 'init'
      refute_equal 0, status
      refute_path_exists runtime
    end
  end
end
