# frozen_string_literal: true

module Tamoz
  module Approval
    Request = Data.define(
      :tool,
      :verb,
      :argv,
      :targets,
      :effect_class,
      :session_id
    )
  end
end
