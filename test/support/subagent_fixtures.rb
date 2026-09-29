# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- the session builder takes one option per scenario knob.

require 'digest'
require 'json'
require_relative 'work_loop_fixtures'
require_relative 'subagent_inspection'

# A parent model and a child model scripted separately over the durable work loop. Plumbing only: every answer is
# written by the test, so nothing here is evidence that a subagent helps a model reason.
module SubagentFixtures
  include WorkLoopFixtures
  include SubagentInspection

  MEMORY_TOOLS = %w[remember forget recall_memory].freeze
  FORBIDDEN_IN_CHILD = (%w[apply_patch create_file run_check delegate update_plan] + MEMORY_TOOLS).freeze
  TASK = 'Find where invoice totals are rounded, then report.'
  BRIEF = 'Find where invoice totals are rounded. Look under lib/billing and lib/export. Return each file:line that ' \
          'rounds, and which rounding mode it uses. If you find nothing, say so.'
  EXPLORE_FILES = {
    'lib/billing/total.rb' => "ROUNDING = :half_even\n",
    'lib/export/csv.rb' => "ROUNDING = :half_up\n",
    'lib/a.rb' => "A = 1\n",
    'lib/b.rb' => "B = 2\n"
  }.freeze
  HAPPY_CHILD = [
    { calls: [['read_file', { 'path' => 'lib/billing/total.rb' }], ['read_file', { 'path' => 'lib/export/csv.rb' }]] },
    { content: 'lib/billing/total.rb:1 rounds half-even; lib/export/csv.rb:1 rounds half-up.' }
  ].freeze
  POND_PROBE = ['probe_pond_log', { 'filter' => 'aerator', 'target' => 'pond-07', 'lookback_minutes' => 60 }].freeze

  # A request is the parent's when its header offers update_plan, which a child is never offered. Each side has its own
  # script; a call nobody scripted raises, so a hidden extra model call fails the test that made it.
  class ScriptedTeam < WorkLoopFixtures::ScriptedConversationModel
    def self.parent_side?(tools) = tools.any? { |tool| tool.dig('function', 'name') == 'update_plan' }

    def initialize(parent:, child: [], **)
      super(turns: parent, **)
      @child_turns = child.dup
      @parent_side = true
    end

    def converse(stage:, messages:, tools:, tool_choice:)
      @parent_side = self.class.parent_side?(tools)
      super
    end

    def parent_requests = requests.select { |bytes| self.class.parent_side?(JSON.parse(bytes).fetch('tools')) }

    def child_requests = requests - parent_requests

    private

    def next_turn(messages)
      return super if @parent_side
      raise 'no scripted child turn left' if @child_turns.empty?

      turn = @child_turns.shift
      turn.respond_to?(:call) ? turn.call(messages) : turn
    end
  end

  def delegate_call(brief = BRIEF, role: 'explore') = ['delegate', { 'role' => role, 'brief' => brief }]

  def delegate_once = [{ calls: [delegate_call] }, { content: 'Totals round in two places.' }]

  def observing(turn)
    lambda do |_messages|
      yield
      turn
    end
  end

  def report_on_probe(messages, evidence: nil)
    id = evidence || messages.find { |message| message['role'] == 'tool' }.fetch('tool_call_id')
    finding = { 'statement' => 'Aerator-2 tripped at 02:10.', 'evidence' => [id] }
    { calls: [['report_findings', { 'summary' => 'Oxygen fell after aerator-2 tripped.', 'hypothesis' => 'Overcurrent.',
                                    'confidence' => 'medium', 'findings' => [finding], 'gaps' => [],
                                    'proposals' => [] }]] }
  end

  def subagent_session(model:, root:, adapter:, profile: 'auto', allowed_tools: nil, subagents: %w[explore],
                       harness: {}, engine: nil, mcp: nil, allow_changes: true, approval_engine: nil)
    checks = allow_changes ? { 'test' => ['true'] } : {}
    Tamoz::Agent::Session.new(
      model:, toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes:, checks:, allowed_tools:),
      checkpointer: adapter, routing: :work,
      approval_engine: approval_engine || Tamoz::Agent.build_approval_engine(profile_name: profile),
      approval_session_id: 'work-test', artifact_store: adapter.bind_artifact_store(tenant: 'work-test'),
      artifact_tenant: 'work-test', harness: subagents.empty? ? harness : harness.merge(subagents:),
      memory: engine, memory_owner: engine && 'alice', mcp:
    )
  end

  # `parent` and `child` are scripts, or callables of the workspace root.
  def delegating(parent: delegate_once, child: HAPPY_CHILD, files: EXPLORE_FILES, task: TASK, model_options: {},
                 **session_options)
    with_work_workspace(files:) do |root, adapter|
      script = ->(value) { value.respond_to?(:call) ? value.call(root) : value }
      model = ScriptedTeam.new(parent: script.call(parent), child: script.call(child), **model_options)
      before = tree_digest(root)
      session = subagent_session(model:, root:, adapter:, **session_options)
      outcome = session.start(task, thread: 'work', request_id: 'work-1')
      yield outcome, model, root, adapter, before
    end
  end

  def assert_child_ran(model) = refute_empty(model.child_requests, 'the child never ran')

  # What an uncrashed run hands the parent, over the same workspace root: the token counts include its path.
  def uncrashed_result(root, child)
    Dir.mktmpdir('tamoz-reference') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'reference.sqlite3'))
      model = ScriptedTeam.new(parent: delegate_once, child:)
      subagent_session(model:, root:, adapter:).start(TASK, thread: 'work', request_id: 'work-1')
      delegation_results(model).first
    ensure
      adapter&.close
    end
  end

  def read_lines(count, path: 'lib/big.rb')
    Array.new(count) do |index|
      { calls: [['read_file', { 'path' => path, 'offset' => (index * 7) + 1, 'limit' => 120 }]] }
    end
  end

  def big_file = (1..400).map { |index| "LINE_#{index} = #{index}  # #{'x' * 40}\n" }.join

  def summary_of(_messages)
    Tamoz::ContextEngine::Compaction::SECTIONS.map { |section| "## #{section}\n- (none)" }.join("\n")
  end
end
# rubocop:enable Metrics/ParameterLists
