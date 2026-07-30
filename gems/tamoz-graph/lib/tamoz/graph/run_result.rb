# frozen_string_literal: true

module Tamoz
  module Graph
    RunResult = Data.define(:status, :snapshot, :interrupts, :errors) do
      def completed? = status == :completed
      def paused? = status == :paused
      def failed? = status == :failed
      def cancelled? = status == :cancelled

      def state
        snapshot.state
      end
    end
  end
end
