# frozen_string_literal: true

module Tamoz
  module SQLite
    BackupReport = Data.define(
      :source,
      :destination,
      :pages,
      :bytes,
      :schema_version,
      :created_at_ms
    )
  end
end
