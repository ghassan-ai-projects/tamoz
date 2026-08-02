# frozen_string_literal: true

module Tamoz
  module Agent
    class Error < Tamoz::Error; end

    # Raised when a model document cannot be parsed. Its message may quote provider
    # text (`Plan.parse` interpolates `JSON::ParserError#message`, `RubyLLMModel`
    # interpolates the provider exception), so it deliberately does NOT include
    # `Tamoz::DisclosableMessage`.
    class ProtocolError < Error; end

    class PlanRejectedError < Error; end
    class ApprovalDeniedError < Error; end

    # A tool refused to act.
    #
    # The base class is terminal by construction: a raise site that has not been
    # classified propagates and ends the session. Only `ToolArgumentError` is ever
    # converted into evidence, and only through `repairable?` — never by matching on
    # message text.
    #
    # Every `ToolError` message is built from Tamoz literals plus Tamoz-computed
    # metadata (digests, counts, limits) or a workspace-relative path or argument name
    # that the same operator already sees in the approval preview and in the durable
    # `review` record, so the class opts in to message disclosure.
    class ToolError < Error
      include Tamoz::DisclosableMessage

      def repairable? = false
    end

    # Sandbox containment and approval integrity: root escape, absolute paths,
    # symlinked components, null bytes, and a workspace that no longer matches the
    # approved before-state. Always terminal — a security rejection must never become
    # a retryable value the planner can iterate against.
    class ToolPolicyError < ToolError; end

    # A failure fully attributable to the arguments the planner chose: text that does
    # not match, an ambiguous match, a stale digest, a missing target, or an argument
    # that fails shape/encoding validation. Nothing was mutated, so the correct
    # response is to re-read the workspace and plan different arguments.
    class ToolArgumentError < ToolError
      def repairable? = true
    end
  end
end
