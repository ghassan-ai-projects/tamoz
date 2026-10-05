# frozen_string_literal: true

module ToolRecoveryFixture
  private

  def scripted_model(plans:, reviews:, final_satisfied:)
    self.class::ScriptedModel.new(
      plan: plans,
      review: Array.new(reviews) { accepted_review },
      verify: [
        {
          'answer' => 'Broken.answer inspection',
          'satisfied' => final_satisfied,
          'evidence' => ['controller-owned evidence']
        }
      ]
    )
  end

  def accepted_review
    { 'decision' => 'accept', 'issues' => [], 'rationale' => 'bounded and independently verifiable' }
  end

  def answer_check
    {
      'answer' => [
        RbConfig.ruby,
        '-I.',
        '-e',
        %q{require './broken'; abort("wrong #{Broken.answer}") unless Broken.answer == 42}
      ]
    }
  end
end
