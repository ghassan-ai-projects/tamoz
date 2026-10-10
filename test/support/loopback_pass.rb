# frozen_string_literal: true

# The loopback channel's whole path through the real CLI: setup, `channel add`, then a gateway pass that admits a
# message and a pass that delivers a reply. Runs in the test process, or alone in a child with no adapter gem on the
# load path (`ruby loopback_pass.rb ROOT DIR`), where it prints what it loaded.
module LoopbackPass
  module_function

  def run(root)
    kind = LoopbackChannel::Kind.new
    kinds = LoopbackChannel.kinds(kind)
    env = { 'ZAI_API_KEY' => 'chat-key', 'LOOPBACK_TOKEN' => 'loop' }
    FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
    runtime = File.join(root, 'runtime')
    cli(runtime, env, kinds, 'setup', '--workspace', workspace, '--chat', 'zai/glm-5.3-flash')
    cli(runtime, env, kinds, 'channel', 'add', 'loopback')
    kind.channel.transport.say(inbound)
    admitted = cli(runtime, env, kinds, 'comms', 'serve', '--once')
    append_reply(runtime, env)
    delivered = cli(runtime, env, kinds, 'comms', 'serve', '--once')
    listed = JSON.parse(cli(runtime, env, kinds, 'comms', 'list', '--json').fetch(1))
    { 'admitted' => admitted.first, 'delivered' => delivered.first,
      'threads' => listed.flat_map { |row| row.fetch('conversations').map { |route| route.fetch('thread_id') } },
      'replies' => kind.channel.transport.delivered.map(&:text) }
  end

  def cli(runtime, env, kinds, *argv)
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime, *argv], out:, err:, input: StringIO.new, env:,
                                                                      channel_kinds: kinds)
    raise "#{argv.join(' ')} exited #{status}: #{err.string}" unless status.zero?

    [status, out.string]
  end

  def inbound
    Tamoz::Comms::InboundEnvelope.new(
      surface_id: 'loopback', surface_revision: 1, update_id: 1, raw_payload_hash: 'a' * 64, parser_version: 1,
      kind: 'text', correspondent_id: 'loopback:user:1', conversation_id: 'loopback:chat:1', text: 'hello',
      observed_time: Time.now.utc
    ).wire
  end

  def append_reply(runtime, env)
    delivery = Tamoz::Comms::Delivery.build(conversation_id: 'loopback:chat:1', kind: 'answer', text: 'hi back',
                                            render_version: 1, content_digest: 'c' * 64, part_index: 0, part_count: 1)
    Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env:)
                     .send(:with_comms_runtime, { runtime_dir: runtime }) do |_directory, _adapter, store, _checkpoints|
      store.append_delivery(delivery.wire, surface_id: 'loopback', capacity: 10, now: Time.now.utc)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root, directory = ARGV
  Dir["#{root}/gems/*/lib"].reject { |lib| lib.match?(%r{/gems/tamoz-(telegram|talk)/}) }.each { $LOAD_PATH << _1 }
  require 'fileutils'
  require 'json'
  require 'stringio'
  require 'tamoz/agent_cli'
  require_relative 'loopback_channel'
  result = LoopbackPass.run(directory)
  adapters = $LOADED_FEATURES.grep(%r{/gems/tamoz-(telegram|talk)/})
  puts JSON.generate(result.merge('adapters_loaded' => adapters))
end
