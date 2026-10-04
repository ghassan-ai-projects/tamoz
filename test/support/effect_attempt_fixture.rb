# frozen_string_literal: true

module EffectAttemptFixture
  private

  def expire_attempt(path, token)
    database = SQLite3::Database.new(path)
    database.execute(
      'UPDATE tamoz_effect_attempts SET deadline_ms = 0 WHERE attempt_token = ?',
      [token]
    )
  ensure
    database&.close
  end
end
