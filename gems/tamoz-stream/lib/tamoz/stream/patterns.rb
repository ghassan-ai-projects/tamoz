# frozen_string_literal: true

module Tamoz
  module Stream
    # Shared validation patterns (one definition per pattern; the P12
    # name-shadowing defect class killed duplicate constants in this module
    # family).
    module Patterns
      ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,255}\z/
      LOWERCASE_ID_PATTERN = /\A[a-z][a-z0-9_.-]{0,255}\z/
      SOURCE_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_:.-]{0,511}\z/
    end
  end
end
