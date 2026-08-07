# frozen_string_literal: true

module Tamoz
  module Graph
    class MemoryCheckpointer
      # The write side of one locked address, handed to the block that
      # `MemoryCheckpointer#transaction` yields.
      #
      # It holds the checkpointer rather than duplicating its storage, so there
      # is exactly one place that appends and one place that reads. The point of
      # the object is the FENCE: a caller reads through it, decides, and appends
      # through it, all inside the lock that produced it, so a decision cannot be
      # taken against one view of an address and written against another.
      #
      # `private_constant :Writer` on the checkpointer keeps this off the public
      # surface — it is reachable only from inside the yielded block.
      #
      # :reek:MissingSafeMethod — `check!` raises on a fence mismatch; a predicate
      # twin would invite checking the fence without acting on it, which is the
      # failure this object exists to prevent.
      # :reek:FeatureEnvy — the writer reads the task and outcome it is handed and
      # turns them into an append; the data is the subject.
      # :reek:LongParameterList :reek:ControlParameter — `append_checkpoint` takes
      # the address, the expected base, the mode and the attributes, and
      # `request_transition` says whether this append also moves the request's
      # state. Both are the append's contract, not hidden switches.
      class Writer
        attr_reader :fence

        def initialize(checkpointer, address)
          @checkpointer = checkpointer
          @thread_id, @namespace = address
          @fence = nil
          freeze
        end

        # The fence check every writer answers. This one has nothing to verify —
        # an in-memory address cannot be fenced out from under us — but it is a
        # COMMAND in a duck-typed interface shared with
        # Tamoz::SQLite::CheckpointWriter and Tamoz::Context, and the executor
        # calls it as `writer.check!`. Returning true is incidental; renaming it
        # to a predicate would break all three implementations at once.
        # rubocop:disable Naming/PredicateMethod
        def check! = true
        # rubocop:enable Naming/PredicateMethod

        def latest
          @checkpointer.latest(thread_id: @thread_id, namespace: @namespace)
        end

        def find(checkpoint_id:)
          @checkpointer.find(
            thread_id: @thread_id,
            namespace: @namespace,
            checkpoint_id:
          )
        end

        def history(limit:, before_sequence: nil)
          entries = @checkpointer.history(
            thread_id: @thread_id,
            namespace: @namespace,
            limit:
          )
          return entries unless before_sequence

          entries.select { |checkpoint| checkpoint.sequence < before_sequence }.first(limit).freeze
        end

        def append_writes(task:, outcome:)
          unless task.id == outcome.task_id &&
                 task.attempt_id == outcome.attempt_id &&
                 task.base_checkpoint_id == outcome.base_checkpoint_id
            raise CheckpointConflictError, 'task outcome identity is stale or mismatched'
          end

          :ephemeral
        end

        def append_checkpoint(
          expected_base_id:,
          mode:,
          attributes:,
          consumed_task_ids: [],
          request_transition: nil
        )
          raise ConfigurationError, 'consumed_task_ids must be an Array' unless consumed_task_ids.is_a?(Array)
          if request_transition
            raise ConfigurationError,
                  'memory checkpointer does not implement durable request transitions'
          end

          @checkpointer.append(
            thread_id: @thread_id,
            namespace: @namespace,
            expected_base_id:,
            mode:,
            attributes:
          )
        end
      end
    end
  end
end
