# frozen_string_literal: true

module Tamoz
  module Agent
    # What a chat correspondent reads when a turn ends: the answer, or one plain sentence on why there is none.
    module ChatReply
      FAILED = "Sorry, something went wrong on my side and I couldn't finish. Please try again."
      GAVE_UP = "I couldn't get this done after several tries. Try rephrasing it or splitting it into smaller steps."
      UNVERIFIED = "I couldn't confirm this worked, so please check it."
      REASONS = {
        'model_key_refused' => "I can't reach my AI model: the provider rejected the API key. " \
                               'Check the key the worker runs with.',
        'model_out_of_credit' => "I can't reach my AI model: the provider account is out of credit. " \
                                 'Top it up or switch provider, then send your message again.',
        'model_rate_limited' => 'My AI model provider is rate-limiting me. Try again in a minute.',
        'model_provider_down' => 'My AI model provider is having trouble. Try again in a few minutes.',
        'model_refused' => 'My AI model provider refused the request. Try again or rephrase it.',
        'approval_denied' => "OK, I didn't do it.",
        'cancelled_by_user' => 'Stopped.',
        'effect_unknown' => "I stopped because I can't tell whether my last action went through. " \
                            'Check the result before asking me to repeat it.',
        'repair_attempts_exhausted' => GAVE_UP,
        'repeated_action' => GAVE_UP,
        'repeated_failure' => GAVE_UP,
        'repeated_tool_failure' => GAVE_UP,
        'repair_plan_rejected' => GAVE_UP,
        'work_failed' => FAILED,
        'done_unverified' => UNVERIFIED
      }.freeze

      module_function

      def completed(view)
        terminal = view.terminal || {}
        caveat = unsatisfied_caveat(view, terminal['reason']) unless terminal['satisfied']
        return caveat if terminal['reason'] == 'work_failed'

        answer = view.state&.dig(:verification, 'answer').to_s.strip
        return [answer, caveat].compact.join("\n\n") unless answer.empty?

        caveat || (terminal['satisfied'] ? 'Done.' : FAILED)
      end

      # A change that nothing verified must say so; an answer needs no check.
      def unsatisfied_caveat(view, reason)
        REASONS.fetch(reason) { UNVERIFIED if view.state&.dig(:route, 'route') == 'managed_action' }
      end

      def stopped(reason, budget: nil)
        return "I stopped because this conversation reached its #{budget.tr('_', ' ')} limit." if budget

        REASONS.fetch(reason, FAILED)
      end
    end
  end
end
