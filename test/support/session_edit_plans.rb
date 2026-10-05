# frozen_string_literal: true

module SessionEditPlans
  private

  def discovery
    {
      'goal' => 'read the current value', 'done_when' => ['app.rb has been read'],
      'steps' => [discovery_step]
    }
  end

  def discovery_step
    {
      'id' => 'look', 'purpose' => 'read the file', 'tool' => 'read_file',
      'arguments' => { 'path' => 'app.rb' }, 'verification' => 'the digest is present'
    }
  end

  def action
    {
      'goal' => 'set value to 2', 'done_when' => ['app.rb contains value = 2 and the check passes'],
      'steps' => [patch_step, check_step]
    }
  end

  def patch_step
    {
      'id' => 'edit', 'purpose' => 'apply the exact replacement', 'tool' => 'apply_patch',
      'arguments' => { 'path' => 'app.rb', 'expected_sha256' => @digest,
                       'before' => 'value = 1', 'after' => 'value = 2' },
      'verification' => 'the receipt reports the new digest'
    }
  end

  def check_step
    {
      'id' => 'check', 'purpose' => 'run the configured check', 'tool' => 'run_check',
      'arguments' => { 'name' => 'answer' }, 'verification' => 'the check exits zero'
    }
  end
end
