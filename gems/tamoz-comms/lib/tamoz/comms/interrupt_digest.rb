# frozen_string_literal: true

require_relative 'canonical'

module Tamoz
  module Comms
    # Canonical digest over the interrupt set a turn is paused on (design §9).
    #
    # Both the worker and `tamoz approve` derive this from the same session
    # view, so a decision records the exact question it answers. Ordering and
    # hash-key insertion order never matter; only the interrupt identities
    # (task_id, call_index) and their full normalized descriptors do.
    module InterruptDigest
      DOMAIN = 'tamoz.comms.interrupts.v1'

      module_function

      # @param interrupts [Array<Hash>] `{task_id:, call_index:, descriptor:}`
      #   in any order; descriptor may be nil.
      # @return [String] 64-char hex digest of the sorted interrupt set.
      def of(interrupts)
        plain = interrupts.map do |interrupt|
          {
            'task_id' => interrupt.fetch(:task_id),
            'call_index' => interrupt.fetch(:call_index),
            'descriptor' => interrupt.fetch(:descriptor) || {}
          }
        end
        sorted = plain.sort_by { |entry| [entry.fetch('task_id'), entry.fetch('call_index')] }
        Canonical.hexdigest(DOMAIN, sorted)
      end
    end
  end
end
