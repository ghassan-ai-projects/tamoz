# frozen_string_literal: true

# A third channel kind that lives only in tests: an in-memory transport behind the same Channel and Setup
# interfaces as Telegram and talk. It proves a new kind needs nothing outside its own code and one registry entry.
module LoopbackChannel
  TOKEN = 'LOOPBACK_TOKEN'
  STREAM = 'loopback:1'

  # Holds what was sent in and out, confirms by cursor like every other transport.
  class Transport
    include Tamoz::Comms::Transport

    attr_reader :delivered, :files

    def initialize
      @inbox = []
      @delivered = []
      @files = {}
      @next_id = 0
    end

    def authenticate = { 'stream_id' => STREAM }

    def say(wire) = @inbox << wire

    def poll(next_offset:, limit:, timeout_s:) # rubocop:disable Lint/UnusedMethodArgument
      @inbox.reject! { |wire| next_offset && wire.fetch('update_id') < next_offset }
      batch = @inbox.first(limit)
      { updates: batch, next_offset: batch.empty? ? nil : batch.last.fetch('update_id') + 1 }
    end

    def deliver(delivery)
      @delivered << delivery
      { 'message_id' => @delivered.length, 'platform_time' => Time.now.utc.iso8601(6) }
    end

    def fetch_attachment(file_id, max_bytes:)
      bytes = @files.fetch(file_id)
      raise Tamoz::Comms::ResponseTooLargeError, 'too large' if bytes.bytesize > max_bytes

      bytes
    end

    def signal(kind, **) = kind == :typing ? :typing : :unsupported
  end

  # The runtime half.
  class Channel
    include Tamoz::Comms::Channel

    # Nothing to open.
    class Connection
      include Tamoz::Comms::Channel::Connection

      attr_reader :transport

      def initialize(transport) = @transport = transport
      def interval_s = 0.01
    end

    attr_reader :transport

    def initialize(transport: Transport.new) = @transport = transport

    def validate!(descriptor)
      raise Tamoz::Comms::ValidationError, 'a loopback surface has no settings' unless descriptor.settings.empty?
    end

    def connect(_descriptor, env:, voice: nil) # rubocop:disable Lint/UnusedMethodArgument
      Connection.new(@transport)
    end
  end

  # The operator half; it records the environment it was handed.
  class Setup
    include Tamoz::Comms::ChannelSetup

    attr_reader :seen_env

    def summary = 'A channel that exists only in tests'
    def env_names = [TOKEN]

    def add(existing:, argv:, env:, state_dir:, terminal:) # rubocop:disable Lint/UnusedMethodArgument
      @seen_env = env
      terminal.say 'Loopback ready.'
      { 'kind' => 'loopback', 'enabled' => true, 'credential_ref' => { 'kind' => 'env', 'name' => TOKEN },
        'stream_id' => STREAM, 'admission' => { 'direct' => 'allowlist', 'correspondents' => ['loopback:user:1'] },
        'approvals' => { 'mode' => 'deny_only', 'prompt_ttl_s' => 900 } }
    end

    def check(env:, **)
      @seen_env = env
      [['token', env[TOKEN].to_s.empty? ? "set #{TOKEN}" : true]]
    end

    # Hands over what it was given, so a test sees exactly what the CLI passed in.
    def gateway_env(env:, **) = (@seen_env = env)
  end

  # A registry entry for it; the same Setup instance each call, so a test can read what it saw.
  class Kind
    attr_reader :setup, :channel

    def initialize
      @setup = Setup.new
      @channel = Channel.new
    end
  end

  module_function

  def kinds(kind = Kind.new) = Tamoz::Agent::CHANNEL_KINDS.merge('loopback' => kind)
end
