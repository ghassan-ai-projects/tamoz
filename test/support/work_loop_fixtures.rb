# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- the scripted provider takes one option per scenario knob.

require 'digest'

# A scripted tool-calling model for the durable work loop. It proves plumbing only:
# every answer is written by the test, so nothing here is evidence the agent reasons.
module WorkLoopFixtures
  DIGEST = "sha256:#{'0' * 64}".freeze

  class ScriptedConversationModel
    attr_reader :requests, :stages, :generations, :crashed_request

    # Simulated process death: raised before a request is sent, so nothing is journaled for it.
    class Crash < Exception; end # rubocop:disable Lint/InheritException

    def initialize(turns:, reviews: nil, summary: nil, window: 20_000, overflow_once: false, crash_at: nil,
                   crash_after: nil)
      @turns = turns.dup
      @reviews = reviews || [{ 'decision' => 'accept', 'issues' => [], 'rationale' => 'fits the task' }]
      @summary = summary
      @window = window
      @overflow_once = overflow_once
      @crash_at = crash_at
      @crash_after = crash_after
      @built = 0
      @requests = []
      @stages = []
      @generations = []
    end

    def model = 'scripted-coder'
    def context_window = @window

    def build_conversation(messages:, tools:, tool_choice:)
      bytes = Tamoz::Core.jcs({ 'messages' => messages, 'tools' => tools, 'tool_choice' => tool_choice })
      @built += 1
      if @built == @crash_at
        @crashed_request = bytes
        raise Crash, 'simulated worker loss'
      end
      bytes
    end

    # The kill-after-effect-started hook the dispatcher calls once an effect is under way.
    def after_effect_started(operation:)
      return unless operation == @crash_after

      @crash_after = nil
      raise Crash, "simulated worker loss after #{operation} started"
    end

    def request_digest(bytes) = "sha256:#{Digest::SHA256.hexdigest(bytes)}"

    def converse(stage:, messages:, tools:, tool_choice:)
      bytes = build_conversation(messages:, tools:, tool_choice:)
      @requests << bytes
      @stages << stage
      if stage == :work_step && @overflow_once
        @overflow_once = false
        raise_overflow
      end
      turn = stage == :work_compact ? { content: @summary.call(messages) } : next_turn(messages)
      response(turn, bytes, messages)
    end

    def generate(stage:, system:, prompt:)
      @generations << { stage:, system:, prompt: }
      review = @reviews.length > 1 ? @reviews.shift : @reviews.first
      JSON.generate(review)
    end

    private

    def next_turn(messages)
      raise 'no scripted turn left' if @turns.empty?

      turn = @turns.shift
      turn.respond_to?(:call) ? turn.call(messages) : turn
    end

    def raise_overflow
      raise Tamoz::Agent::ModelCallError.new(code: 'context_window_exceeded', status: 400)
    end

    def response(turn, bytes, messages)
      calls = Array(turn[:calls]).each_with_index.map do |(name, arguments), index|
        { 'id' => "call_#{@requests.length}_#{index}", 'name' => name, 'arguments' => JSON.generate(arguments) }
      end
      finish_reason = turn.fetch(:finish_reason) { calls.empty? ? 'stop' : 'tool_calls' }
      Tamoz::Agent::EpisodeModelTransport::Conversation.new(
        content: turn.fetch(:content, ''), tool_calls: calls, finish_reason:,
        usage: { 'prompt_tokens' => Tamoz::Core.jcs(messages).bytesize / 4, 'completion_tokens' => 5 },
        request_digest: request_digest(bytes), response_digest: request_digest(JSON.generate(turn.to_s)),
        settings_digest: DIGEST, provider_configuration_digest: DIGEST
      )
    end
  end

  def with_work_workspace(files: {})
    Dir.mktmpdir('tamoz-work') do |directory|
      root = File.join(directory, 'workspace')
      FileUtils.mkdir_p(root)
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), text)
      end
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'tamoz.sqlite3'),
                                           limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2))
      yield File.realpath(root), adapter
    ensure
      adapter&.close
    end
  end

  def work_session(model:, root:, adapter:, profile: 'auto', checks: { 'test' => ['true'] }, harness: {})
    Tamoz::Agent::Session.new(
      model:, toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks:), checkpointer: adapter,
      routing: :work, approval_engine: Tamoz::Agent.build_approval_engine(profile_name: profile),
      approval_session_id: 'work-test', artifact_store: adapter.bind_artifact_store(tenant: 'work-test'),
      artifact_tenant: 'work-test', harness:
    )
  end

  def plan_call(paths: %w[lib], checks: %w[test])
    ['update_plan', { 'goal' => 'Fix the value', 'done_when' => ['test passes'],
                      'scope' => { 'paths' => paths, 'checks' => checks },
                      'steps' => [{ 'title' => 'Edit the value', 'status' => 'in_progress' }] }]
  end

  def read_call(path) = ['read_file', { 'path' => path }]

  def patch_call(root, path, before, after)
    sha = Digest::SHA256.hexdigest(File.read(File.join(root, path)))
    ['apply_patch', { 'path' => path, 'expected_sha256' => sha, 'before' => before, 'after' => after }]
  end

  def tool_results(model)
    JSON.parse(model.requests.last).fetch('messages').select { |message| message['role'] == 'tool' }
                                                     .map { |message| message.fetch('content') }
  end
end
# rubocop:enable Metrics/ParameterLists
