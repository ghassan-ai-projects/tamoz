# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/telegram_cli_fixture'

# `tamoz service` against a fake launchctl and a temporary LaunchAgents folder; nothing reaches the real launchd.
class CliServiceTest < Minitest::Test
  include TelegramCliFixture

  KEYS = { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:secret-token', 'ZAI_API_KEY' => 'zai-secret-key' }.freeze
  Exit = Struct.new(:code) do
    def success? = code.zero?
  end

  def with_service
    with_dirs do |runtime, workspace|
      cli(runtime, %W[setup --workspace #{workspace} --chat zai/glm-5.3-flash], bot: Bot.new([]))
      cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))
      env_file = File.join(File.dirname(runtime), '.env')
      File.write(env_file, KEYS.map { |name, value| "#{name}=#{value}" }.join("\n"))
      File.chmod(0o600, env_file)
      yield runtime, env_file, FileUtils.mkdir_p(File.join(File.dirname(runtime), 'LaunchAgents')).first
    end
  end

  # launchctl list reports the labels in loaded; bootstrap exits with bootstrap_exit.
  def fake_cli(io, agents, loaded, calls, bootstrap_exit: 0)
    cli = Tamoz::Agent::CLI.new(**io, input: StringIO.new, env: {}, channel_kinds: ChannelKindsFixture.telegram(lambda { |_|
      Bot.new([])
    }),
                                      model_factory: lambda { |**|
                                        Object.new.tap do |model|
                                          model.define_singleton_method(:generate) do |**|
                                            'ok'
                                          end
                                        end
                                      })
    cli.define_singleton_method(:launch_agents) { agents }
    list = loaded.map { |label| "4242\t0\t#{label}\n" }.join
    cli.define_singleton_method(:launchctl) do |*args|
      calls << args
      next [list, Exit.new(0)] if args.first == 'list'

      args.first == 'bootstrap' ? ['Bootstrap failed: 5', Exit.new(bootstrap_exit)] : ['', Exit.new(0)]
    end
    cli
  end

  def service(runtime, agents, *argv, loaded: [], bootstrap_exit: 0)
    io = { out: StringIO.new, err: StringIO.new }
    calls = []
    cli = fake_cli(io, agents, loaded, calls, bootstrap_exit:)
    [cli.run(['--runtime-dir', runtime, 'service', *argv]), io[:out].string, io[:err].string, calls]
  end

  def plists(agents) = Dir[File.join(agents, '*.plist')].map { File.basename(_1) }.sort

  def test_install_writes_one_private_job_per_child_and_loads_it
    with_service do |runtime, env_file, agents|
      status, _out, err, calls = service(runtime, agents, 'install', '--env-file', env_file)

      assert_equal 0, status, err
      assert_equal [%w[com.tamoz.telegram-gateway.plist com.tamoz.worker.plist], [0o600]],
                   [plists(agents), Dir[File.join(agents, '*.plist')].map { File.stat(_1).mode & 0o777 }.uniq]
      assert_equal(2, calls.count { |args| args.first == 'bootstrap' })
    end
  end

  def test_each_job_carries_only_its_childs_keys
    with_service do |runtime, env_file, agents|
      service(runtime, agents, 'install', '--env-file', env_file)
      worker = File.read(File.join(agents, 'com.tamoz.worker.plist'))
      gateway = File.read(File.join(agents, 'com.tamoz.telegram-gateway.plist'))

      assert_equal [true, false, true, false],
                   [worker.include?('zai-secret-key'), worker.include?('secret-token'),
                    gateway.include?('secret-token'), gateway.include?('zai-secret-key')]
    end
  end

  def test_no_output_carries_a_secret
    with_service do |runtime, env_file, agents|
      _status, out, err, = service(runtime, agents, 'install', '--env-file', env_file)
      status_out = service(runtime, agents, 'status')[1]

      refute_match(/secret/, out + err + status_out)
    end
  end

  def test_install_needs_an_env_file
    with_service do |runtime, _env_file, agents|
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, service(runtime, agents, 'install').first
    end
  end

  def test_install_on_a_running_service_is_refused
    with_service do |runtime, env_file, agents|
      service(runtime, agents, 'install', '--env-file', env_file)
      status, _out, err, = service(runtime, agents, 'install', '--env-file', env_file,
                                   loaded: %w[com.tamoz.worker])

      assert_equal 1, status
      assert_includes err, '`tamoz service uninstall`'
    end
  end

  def test_status_names_each_job_and_never_prints_launchd_state
    with_service do |runtime, env_file, agents|
      service(runtime, agents, 'install', '--env-file', env_file)
      _status, out, _err, calls = service(runtime, agents, 'status', loaded: %w[com.tamoz.worker])

      assert_includes out, 'com.tamoz.worker: pid 4242'
      assert_includes out, 'com.tamoz.telegram-gateway: not running'
      refute(calls.any? { |args| args.first == 'print' })
    end
  end

  def test_uninstall_unloads_the_jobs_and_keeps_their_plists_aside
    with_service do |runtime, env_file, agents|
      service(runtime, agents, 'install', '--env-file', env_file)
      _status, _out, _err, calls = service(runtime, agents, 'uninstall')

      assert_empty plists(agents)
      assert_equal 2, Dir[File.join(runtime, 'service-backups', '*', '*.plist')].length
      assert_equal(2, calls.count { |args| args.first == 'bootout' })
    end
  end

  def test_a_job_launchd_will_not_load_fails_the_install_naming_it
    with_service do |runtime, env_file, agents|
      status, _out, err, = service(runtime, agents, 'install', '--env-file', env_file, bootstrap_exit: 5)

      assert_equal 1, status
      assert_includes err, 'launchctl could not load com.tamoz.telegram-gateway (Bootstrap failed: 5)'
    end
  end

  def test_a_job_that_stays_loaded_keeps_its_plist
    with_service do |runtime, env_file, agents|
      service(runtime, agents, 'install', '--env-file', env_file)
      service(runtime, agents, 'uninstall', loaded: %w[com.tamoz.worker])

      assert_equal %w[com.tamoz.worker.plist], plists(agents)
    end
  end

  def test_another_runtimes_jobs_are_left_alone
    with_service do |runtime, _env_file, agents|
      File.write(other = File.join(agents, 'com.tamoz.other.plist'), '<string>/somewhere/else</string>')
      service(runtime, agents, 'uninstall')

      assert_path_exists other
    end
  end

  def test_start_is_refused_while_the_service_runs_this_runtime
    with_service do |runtime, env_file, agents|
      service(runtime, agents, 'install', '--env-file', env_file)
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: err = StringIO.new, input: StringIO.new, env: KEYS)
      cli.define_singleton_method(:launch_agents) { agents }
      cli.define_singleton_method(:launchctl) { |*| ["4242\t0\tcom.tamoz.worker\n", Exit.new(0)] }

      assert_equal 1, cli.run(['--runtime-dir', runtime, 'start'])
      assert_includes err.string, 'the service already runs this runtime'
    end
  end
end
