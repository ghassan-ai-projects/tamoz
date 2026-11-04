# frozen_string_literal: true

require 'json'
require_relative 'talk_audio'
require_relative 'talk_checks'
require_relative 'talk_scenarios/heard_grading'
require_relative 'talk_scenarios/answer_grading'
require_relative 'talk_scenarios/action_grading'
require_relative 'talk_scenarios/answer_drivers'
require_relative 'talk_scenarios/approval_drivers'
require_relative 'talk_scenarios/session_drivers'

# The talk eval's scenarios: drivers collect observations from a running channel; graders are pure, so the
# controls test can show each one failing on an adversary without a model.
module TalkScenarios
  Result = Struct.new(:scenario, :input, :outcome, :detail, keyword_init: true)
  ECHO_LABEL = File.expand_path('../../gems/tamoz-harness/prompts/attachment_text.json', __dir__)

  extend HeardGrading
  extend AnswerGrading
  extend ActionGrading
  extend AnswerDrivers
  extend ApprovalDrivers
  extend SessionDrivers

  module_function

  def spec = TalkChecks.spec
  def config(name) = spec.fetch('scenarios').fetch(name)
  def script(id) = spec.fetch('scripts').find { |entry| entry.fetch('id') == id }
  def text(id) = script(id).fetch('text')
  def result(scenario, input, outcome, detail = nil) = Result.new(scenario:, input:, outcome:, detail:)

  def judged(scenario, input, problems)
    result(scenario, input, problems.empty? ? :pass : :fail,
           problems.empty? ? nil : problems.join('; '))
  end

  def heard_scripts
    split, prefix = config('heard_clean').fetch('scripts').split(':')
    spec.fetch('scripts').select { |entry| entry.fetch('split') == split && entry.fetch('id').start_with?(prefix) }
  end

  def wav(corpus, id, voice: 'Samantha', variant: 'clean')
    File.binread(File.join(corpus, variant, voice, "#{id}.wav"))
  end
end
