# frozen_string_literal: true

require 'socket'

# A talk surface descriptor, hub and raw HTTP client for the talk tests; real sockets on 127.0.0.1, ephemeral ports.
module TalkFixtures
  TOKEN = 'talk-test-token-0123456789abcdef'
  LIMITS = { max_inbound_bytes: 8192, max_open_requests: 50, max_denial_prompts_per_request: 4, outbox_capacity: 500,
             control_capacity: 50, per_chat_messages_per_s: 20.0, global_messages_per_s: 50.0 }.freeze

  def talk_descriptor(allow_hosts: ['mac.tail.ts.net'], revision: 1)
    Tamoz::Comms::SurfaceDescriptor.build(
      surface_id: 'talk', revision:, kind: 'talk',
      transport: { mode: 'long_poll', credential_ref: { kind: 'env', name: 'TAMOZ_TALK_TOKEN' }, poll_timeout_s: 1,
                   batch: 50, max_response_bytes: nil, port: 8787, allow_hosts: },
      identity: { expected_bot_id: 123_456_789_012 },
      admission: { direct: 'allowlist', correspondents: ['talk:user:1'] }, threading: 'conversation',
      profile_id: 'talk', approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' }, limits: LIMITS
    )
  end

  def start_hub(**)
    defaults = { descriptor: talk_descriptor, token: TOKEN, floor: 0, port: 0, submit_timeout_s: 0.5,
                 deadlines: { head: 0.5, body: 0.5 } }
    @hubs = (@hubs || []) << Tamoz::Talk::Hub.new(**defaults, **).start
    @hubs.last
  end

  def stop_hubs = Array(@hubs).each(&:stop)

  def eventually(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise 'the condition never held' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  Response = Struct.new(:status, :headers, :body)

  def raw(hub, bytes, read: true)
    socket = TCPSocket.new('127.0.0.1', hub.port)
    socket.write(bytes)
    return socket unless read

    parse(socket.read)
  ensure
    socket&.close if read
  end

  def http(hub, method, path, body: '', token: TOKEN, host: "127.0.0.1:#{hub.port}", headers: {})
    head = "#{method} #{path} HTTP/1.1\r\nHost: #{host}\r\nContent-Length: #{body.bytesize}\r\n"
    head << "Authorization: Bearer #{token}\r\n" if token
    headers.each { |name, value| head << "#{name}: #{value}\r\n" }
    raw(hub, head.b + "\r\n".b + body.b)
  end

  def parse(text)
    head, body = text.b.split("\r\n\r\n".b, 2)
    status_line, *fields = head.to_s.split("\r\n")
    headers = fields.to_h { |field| field.split(': ', 2).then { |name, value| [name.downcase, value] } }
    Response.new(status_line.to_s.split[1].to_i, headers, body.to_s)
  end

  def wav(seconds, rate: 16_000, channels: 1, bits: 16)
    data = "\x00\x01".b * (rate * seconds * channels).to_i
    format = [1, channels, rate, rate * channels * bits / 8, channels * bits / 8, bits].pack('vvVVvv')
    "RIFF#{[36 + data.bytesize].pack('V')}WAVEfmt #{[16].pack('V')}".b + format + "data#{[data.bytesize].pack('V')}".b + data
  end

  # Confirms every batch as the gateway would: poll, then poll again with the returned offset.
  def confirm_all(hub)
    batch = hub.inbox.poll(next_offset: nil, limit: 50, timeout_s: 1)
    hub.inbox.poll(next_offset: batch[:next_offset], limit: 50, timeout_s: 0)
    batch[:updates]
  end
end
