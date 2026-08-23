# frozen_string_literal: true

require "socket"
require "json"
require "digest"
require "net/http"
require "uri"
require "tamoz/core"

# P1 test infrastructure: a real, separately-controlled local model endpoint.
#
# The design (§4.3) requires P1 to hit a real endpoint that logs the raw
# request/response digests OUTSIDE the worker — not a fake RubyLLM context,
# which the anti-cheat protocol rejects as "not a real model call". Two modes:
#
#   - :proxy — forwards the worker's request to a REAL pinned upstream model
#     server (ollama's OpenAI-compatible /v1 in the P1 environment) and logs
#     the exact request/response bytes it forwards. Gates 1-2 use this mode:
#     the digests the endpoint observes are compared against the Tamoz
#     receipt's digests, byte for byte.
#   - :fixture — serves scripted OpenAI-compatible responses (in order) over
#     the same real HTTP boundary, logging the same digests. Used ONLY for the
#     perturbation control (gate 3, output dependence is a plumbing property)
#     and unit tests. Fixture runs are labeled `fixture` and are never shown
#     as evidence of a real model path.
#
# The request bytes arrive verbatim from the frozen episode transport (the
# canonical JCS body), so `digest(body)` here equals the receipt's request
# digest by construction; the response digest is over the exact envelope bytes
# the endpoint sends.
class LocalModelEndpoint
  attr_reader :port, :log_path, :mode

  # The fixture-envelope model marker (domain-agnostic; the same literal in
  # benchmark_run / crash_matrix_test stays independent of this constant).
  MODEL_MARKER = "local-model"

  def initialize(mode:, log_path:, upstream: nil, responses: nil)
    raise ArgumentError, "mode must be :proxy or :fixture" unless %i[proxy fixture].include?(mode.to_sym)
    if mode.to_sym == :proxy && upstream.to_s.empty?
      raise ArgumentError, "proxy mode requires an upstream base URL"
    end
    if mode.to_sym == :fixture && (responses.nil? || responses.empty?)
      raise ArgumentError, "fixture mode requires responses"
    end

    @mode = mode.to_sym
    @upstream = upstream.to_s.sub(%r{/+\z}, "")
    @responses = responses
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @index = 0
    File.write(log_path, "")
    @log_path = log_path
  end

  def base_url = "http://127.0.0.1:#{@port}/v1"

  def start
    @thread = Thread.new do
      loop do
        client = begin
          @server.accept
        rescue StandardError
          break
        end
        handle(client)
      end
    end
    self
  end

  def stop
    begin
      @server.close
    rescue StandardError
      nil
    end
    @thread&.kill
  end

  # The digests the endpoint observed, oldest first — read back by the test
  # and compared independently against the worker's receipts.
  def observed
    File.readlines(@log_path).map { |line| JSON.parse(line) }
  end

  private

  def handle(client)
    request_bytes = Tamoz::Core::RawHttp.read_request(client)
    return if request_bytes.nil?

    if @mode == :fixture
      content = @responses[@index] || @responses.last
      @index += 1
      envelope = fixture_envelope(content)
      append_log(request_bytes:, response_bytes: envelope)
      Tamoz::Core::RawHttp.write_response(client, envelope, status: 200)
    else
      status, body = forward(request_bytes)
      append_log(request_bytes:, response_bytes: body, upstream_status: status)
      Tamoz::Core::RawHttp.write_response(client, body, status:)
    end
  rescue StandardError
    nil
  ensure
    begin
      client&.close
    rescue StandardError
      nil
    end
  end

  def forward(request_bytes)
    uri = URI.parse("#{@upstream}/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 300
    http.open_timeout = 60
    response = http.request(
      Net::HTTP::Post.new(uri, "Content-Type" => "application/json"),
      request_bytes
    )
    [response.code.to_i, response.body.to_s]
  end

  def fixture_envelope(content)
    JSON.generate(
      id: "chatcmpl-local",
      object: "chat.completion",
      model: MODEL_MARKER,
      choices: [{index: 0, message: {role: "assistant", content: content}, finish_reason: "stop"}],
      usage: {prompt_tokens: 42, completion_tokens: 21, total_tokens: 63}
    )
  end

  def append_log(request_bytes:, response_bytes:, upstream_status: nil)
    entry = {
      "request_digest" => digest(request_bytes),
      "response_digest" => digest(response_bytes),
      "request_bytes" => request_bytes.bytesize,
      "response_bytes" => response_bytes.bytesize
    }
    entry["upstream_status"] = upstream_status if upstream_status
    File.open(@log_path, "a") { |file| file.puts(JSON.generate(entry)) }
  end

  def digest(bytes) = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
end
