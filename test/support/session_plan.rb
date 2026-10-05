# frozen_string_literal: true

module SessionPlan
  private

  def plan_for(tool, arguments, id: 's1')
    {
      'goal' => 'answer the task',
      'done_when' => ['the tool returned evidence'],
      'steps' => [
        {
          'id' => id,
          'purpose' => 'gather evidence',
          'tool' => tool,
          'arguments' => arguments,
          'verification' => 'the output is present'
        }
      ]
    }
  end
end
