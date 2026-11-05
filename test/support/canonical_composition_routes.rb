# frozen_string_literal: true

require_relative 'openclaw_comms_fixture'

module CanonicalCompositionRoutes
  Fixture = Tamoz::Evals::Benchmark::OpenclawCommsFixture

  CONVERSATION_A = Fixture::CONVERSATION_A
  CONVERSATION_B = Fixture::CONVERSATION_B
  # The fixture pre-binds its own USER_BOUND on conversation A even in
  # pairing mode, so the composed story pairs two correspondents of its own.
  USER_A = 31_415_926
  USER_B = 27_182_818
  SURFACE_ID = Fixture::SURFACE_ID

  MARKER_ONE_A = 'LEG-A-ONE'
  MARKER_OPS_A = 'LEG-A-OPS'
  MARKER_SLOW = 'LEG-A-SLOW'
  MARKER_ONE_B = 'LEG-B-ONE'
  MARKER_OPS_B = 'LEG-B-OPS'
  MARKER_CRASH = 'LEG-B-CRASH'
  MARKER_FINAL = 'LEG-B-FINAL'

  READ_PLAN = {
    'goal' => 'answer the task', 'done_when' => ['the tool returned evidence'],
    'steps' => [{ 'id' => 's1', 'purpose' => 'gather evidence', 'tool' => 'read_file',
                  'arguments' => { 'path' => 'note.txt' },
                  'verification' => 'the output is present' }]
  }.freeze

  # Both conversations share one profile, so the runtime memoizes ONE model
  # for every thread; prompts carry the task text, and each leg names itself,
  # so the router hands each generate to that leg's own scripted queues.
  # Newest-first matching keeps a later leg's marker ahead of the earlier
  # markers its own transcript nests.
  class PromptRoutedModel
    def initialize(routes)
      @routes = routes
    end

    def generate(stage:, system:, prompt:)
      matched = @routes.find { |marker, _model| prompt.include?(marker) }
      raise KeyError, "no scripted leg for #{stage}" unless matched

      matched.last.generate(stage:, system:, prompt:)
    end
  end

  private

  def build_routes
    shared = Fixture.model_factory(
      plan: [READ_PLAN], review: [Fixture::ACCEPTED_REVIEW],
      verify: [Fixture::VERIFY_OK.first]
    ).call(nil)
    crash = Fixture.crashing_factory(
      after: :plan, plan: [READ_PLAN], review: [Fixture::ACCEPTED_REVIEW],
      verify: [Fixture::VERIFY_OK.first]
    ).call(nil)
    slow = slow_park_leg_model
    PromptRoutedModel.new(
      [[MARKER_FINAL, shared], [MARKER_CRASH, crash], [MARKER_SLOW, slow],
       [MARKER_OPS_B, shared], [MARKER_OPS_A, shared],
       [MARKER_ONE_B, shared], [MARKER_ONE_A, shared]]
    )
  end

  def slow_park_leg_model
    inspect_step = { 'id' => 'look', 'purpose' => 'read the note', 'tool' => 'read_file',
                     'arguments' => { 'path' => 'note.txt' },
                     'verification' => 'the output is present' }
    edit_step = { 'id' => 'edit', 'purpose' => 'apply the exact replacement', 'tool' => 'apply_patch',
                  'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                  'verification' => 'the receipt reports the new digest' }
    Fixture.model_factory(
      plan: [
        { 'goal' => 'inspect then fix note.txt', 'done_when' => ['note.txt reads fixed'],
          'steps' => [inspect_step] },
        { 'goal' => 'fix note.txt', 'done_when' => ['note.txt reads fixed'],
          'steps' => [edit_step] }
      ],
      review: [Fixture::ACCEPTED_REVIEW, Fixture::ACCEPTED_REVIEW],
      verify: [{ 'answer' => 'fixed', 'satisfied' => true, 'evidence' => ['note.txt'] }]
    ).call(nil)
  end
end
