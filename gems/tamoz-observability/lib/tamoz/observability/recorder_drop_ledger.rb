# frozen_string_literal: true

module Tamoz
  module Observability
    module Recorder
      # Validation and drop-accounting shared by the in-memory and journal
      # recorders. Both maintain the same drop ledger (reason-keyed counters)
      # and the same fail-soft record envelope; the invariant is that a full or
      # invalid signal is COUNTED, never raised, unless the recorder is strict.
      #
      # Including classes must provide:
      #   @drops    a Hash.new(0) drop ledger
      #   @catalog  the signal catalog
      #   @strict   fail-closed flag
      #   #synchronize  a lock guarding @drops
      # and pass the accept action (store/route) as the block of #guard_record.
      module DropLedger
        private

        def guard_record(signal)
          validate!(signal)
          yield
        rescue ValidationError
          raise if @strict

          count_invalid_drop
          :dropped
        rescue StandardError
          raise if @strict

          count_drop('record', 'error', 'bulk')
          :dropped
        end

        def validate!(signal)
          raise ValidationError, 'record expects a Signal' unless signal.is_a?(Signal)

          @catalog.validate_signal(signal)
        end

        def count_invalid_drop
          count_drop('invalid', 'validation', 'bulk')
        end

        def count_drop(name, reason, lane)
          synchronize { @drops[drop_key(name, reason, lane)] += 1 }
        end

        def drop_key(name, reason, lane)
          "#{name}:#{reason}:#{lane}"
        end

        def drops_hash
          @drops.to_h { |(name, reason, lane), count| [drop_key(name, reason, lane), count] }
        end
      end
    end
  end
end
