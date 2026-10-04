# frozen_string_literal: true

module ReadNotePlan
  private

  def read_plan
    {
      'goal' => 'explain',
      'done_when' => ['read the note'],
      'steps' => [
        {
          'id' => 's1', 'purpose' => 'read', 'tool' => 'read_file',
          'arguments' => { 'path' => 'note.txt' }, 'verification' => 'output present'
        }
      ]
    }
  end
end
