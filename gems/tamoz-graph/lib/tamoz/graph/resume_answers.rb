# frozen_string_literal: true

module Tamoz
  module Graph
    # Validates and immutably merges answers for a paused graph checkpoint.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy -- the merger owns the durable
    # answer shape, so these local hash transformations stay here at the boundary.
    # :reek:NestedIterators :reek:TooManyStatements -- answer validation must walk
    # task ids and call indexes in order to preserve the existing error precedence.
    # :reek:UtilityFunction -- expected-index and copy helpers are pure transformations
    # kept beside the answer contract rather than exposed as shared utilities.
    class ResumeAnswers
      def initialize(codec:)
        @codec = codec
        freeze
      end

      def stale_reason(checkpoint, request)
        return 'latest checkpoint is not paused' unless checkpoint&.status == :paused

        answers = request.payload
        return 'resume answers must be a Hash' unless answers.is_a?(Hash)
        return 'resume answers cannot be empty' if answers.empty?

        expected = expected_indices(checkpoint)
        invalid_answer_reason(answers, expected) || duplicate_answer_reason(checkpoint, answers)
      end

      def merge(checkpoint, answers)
        additions = additions_for(answers, expected_indices(checkpoint))
        merged = copy_values(checkpoint.resume_values)
        merge_additions(merged, additions)
      end

      private

      attr_reader :codec

      def expected_indices(checkpoint)
        checkpoint.interrupts.to_h do |interrupt|
          [[interrupt.task_id, interrupt.call_index], true]
        end
      end

      def invalid_answer_reason(answers, expected)
        answers.each do |raw_task_id, raw_indices|
          task_id = String(raw_task_id)
          return 'resume task answers must be a Hash' unless raw_indices.is_a?(Hash)

          raw_indices.each_key do |raw_index|
            index = Integer(raw_index, exception: false)
            return 'resume answer does not match an outstanding task/call index' unless
              index && index >= 0 && expected.key?([task_id, index])
          end
        end
        nil
      end

      def duplicate_answer_reason(checkpoint, answers)
        answers.each do |raw_task_id, raw_indices|
          task_id = String(raw_task_id)
          raw_indices.each_key do |raw_index|
            index = Integer(raw_index, exception: false)
            next unless index && index >= 0

            values = checkpoint.resume_values.fetch(task_id, nil)
            return "resume answer already exists for call index #{index}" if values&.key?(index)
          end
        end
        nil
      end

      def additions_for(answers, expected)
        raise InvalidUpdateError, 'resume answers must be a Hash' unless answers.is_a?(Hash)

        additions = answers.each_with_object({}) do |(raw_task_id, raw_indices), result|
          task_id = String(raw_task_id)
          result[task_id] = normalized_indices(task_id, raw_indices, expected)
        end
        raise InvalidUpdateError, 'resume answers cannot be empty' if additions.empty?

        additions
      end

      def normalized_indices(task_id, raw_indices, expected)
        raise InvalidUpdateError, 'resume task answers must be a Hash' unless raw_indices.is_a?(Hash)

        raw_indices.each_with_object({}) do |(raw_index, value), result|
          index = Integer(raw_index, exception: false)
          unless index && index >= 0 && expected.key?([task_id, index])
            raise InvalidUpdateError, 'resume answer does not match an outstanding task/call index'
          end

          result[index] = codec.normalize(value)
        end
      end

      def copy_values(values)
        values.to_h { |task_id, entries| [task_id, entries.dup] }
      end

      def merge_additions(merged, additions)
        additions.each do |task_id, values|
          merged[task_id] ||= {}
          values.each do |index, value|
            if merged.fetch(task_id).key?(index)
              raise InvalidUpdateError, "resume answer already exists for #{task_id}/#{index}"
            end

            merged.fetch(task_id)[index] = value
          end
        end
        merged.transform_values(&:freeze).freeze
      end
    end
  end
end
