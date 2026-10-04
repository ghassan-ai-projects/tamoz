# frozen_string_literal: true

module SQLiteScenarioFixture
  private

  def subject
    {
      'id' => 'tamoz-sqlite',
      'version' => Tamoz::SQLite::VERSION,
      'git_revision' => 'a' * 40,
      'git_tree' => 'b' * 40,
      'dirty' => false
    }
  end
end
