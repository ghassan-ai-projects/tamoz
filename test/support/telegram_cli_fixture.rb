# frozen_string_literal: true

require 'tmpdir'

# A scripted Bot API and a runtime made by `tamoz setup`, for the Telegram CLI tests.
module TelegramCliFixture
  BOT = { 'id' => 7_000_000_001, 'username' => 'tamoz_test_bot', 'is_bot' => true }.freeze
  OWNER = 5_640_479_090

  # Answers getMe as BOT and hands out the scripted updates once.
  class Bot
    attr_reader :calls

    def initialize(updates)
      @updates = updates
      @calls = []
    end

    def origin = 'https://api.telegram.org'

    def call(method, params, idempotent: false) # rubocop:disable Lint/UnusedMethodArgument
      @calls << [method, params]
      case method
      when 'getMe' then BOT
      when 'getWebhookInfo' then { 'url' => '' }
      when 'getUpdates' then @updates.shift(@updates.length).select { |u| u['update_id'] >= params['offset'].to_i }
      else { 'message_id' => 1, 'date' => 1 }
      end
    end
  end

  def with_dirs
    Dir.mktmpdir('tamoz-telegram-cli') do |root|
      workspace = File.join(root, 'workspace')
      FileUtils.mkdir_p(workspace)
      yield File.join(root, 'runtime'), workspace
    end
  end

  def cli(runtime, argv, bot:, input: '', env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '123:test' })
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime] + argv, out:, err:, input: StringIO.new(input),
                                                                      env:, comms_client_factory: ->(_token) { bot })
    [status, out.string, err.string]
  end

  def set_up_runtime(runtime, workspace) = cli(runtime, %W[setup --workspace #{workspace}], bot: Bot.new([]))

  def pair(runtime, workspace)
    set_up_runtime(runtime, workspace)
    cli(runtime, %W[channel add telegram --owner #{OWNER}], bot: Bot.new([]))
  end
end
