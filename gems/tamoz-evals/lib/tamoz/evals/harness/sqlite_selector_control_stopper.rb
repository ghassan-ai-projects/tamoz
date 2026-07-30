# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteSelectorControl
        class Stopper
          def initialize(layout:, scenario:, selector:, registry:)
            SQLiteSelectorControl.send(:validate_layout!, layout)
            @layout = layout
            @registry = registry
            @expectation = SQLiteSelectorControl.send(
              :build_expectation,
              scenario:,
              selector:,
              registry:
            )
            SQLiteSelectorControl.send(:ensure_control_absent!, @layout)
            @owner_process = Process.pid
            @owner_thread = Thread.current
            @occurrences = Hash.new(0)
            @state = :armed
          end

          def call(point, metadata)
            ensure_owner!
            unless @state == :armed
              raise ExecutionError, "selector stopper is not armed"
            end

            point_name = normalize_point(point)
            unless SQLiteSelectorControl.send(:deeply_frozen?, metadata)
              fail_control!("selector stopper hook must be deeply frozen")
            end
            validate_hook!(point_name, metadata)
            unless metadata.fetch("operation") ==
                   @expectation.selector.fetch("operation")
              fail_control!("selector stopper observed an unexpected operation")
            end
            unless metadata.fetch("attempt") == 1
              fail_control!("Phase 2 selector stopper requires attempt one")
            end

            key = [
              point_name,
              metadata.fetch("operation"),
              metadata.fetch("statement"),
              metadata.fetch("attempt")
            ].freeze
            occurrence = @occurrences[key] + 1
            if occurrence > MAX_OCCURRENCE
              fail_control!(
                "selector stopper exceeds #{MAX_OCCURRENCE} occurrences"
              )
            end
            @occurrences[key] = occurrence

            expected = @expectation.hook
            return nil unless point_name == expected.fetch("point") &&
                              metadata.fetch("operation") == expected.fetch("operation") &&
                              metadata.fetch("statement") == expected.fetch("statement") &&
                              metadata.fetch("attempt") == expected.fetch("attempt") &&
                              occurrence == expected.fetch("occurrence")

            actual = DeepFreeze.call(
              {
                "point" => point_name.dup.freeze,
                "hook_version" => metadata.fetch("hook_version"),
                "kind" => metadata.fetch("kind").dup.freeze,
                "operation" => metadata.fetch("operation").dup.freeze,
                "statement" => metadata.fetch("statement")&.dup&.freeze,
                "attempt" => metadata.fetch("attempt"),
                "occurrence" => occurrence
              }
            )
            unless actual == expected
              fail_control!("selector stopper observed hook does not match selector")
            end

            write_control!
            @state = :stopped
            Process.kill("STOP", Process.pid)
            @state = :failed
            raise ExecutionError,
                  "selector child resumed after SIGSTOP without parent SIGKILL"
          rescue ExecutionError
            @state = :failed unless @state == :stopped
            raise
          rescue StandardError => error
            @state = :failed
            raise ExecutionError.new(
              "selector stopper failed: #{error.class}"
            ), cause: error
          end

          def finish!
            ensure_owner!
            unless @state == :armed
              raise ExecutionError, "selector stopper cannot finish from #{@state}"
            end

            @state = :failed
            raise ExecutionError, "SQLite selector was not reached"
          end

          private

          def ensure_owner!
            unless Process.pid == @owner_process
              raise ExecutionError,
                    "selector stopper must be constructed after child process start"
            end
            unless Thread.current.equal?(@owner_thread)
              raise ExecutionError,
                    "selector stopper hook must run on its owner thread"
            end
          end

          def normalize_point(point)
            unless point.is_a?(String) || point.is_a?(Symbol)
              fail_control!("selector stopper point is invalid")
            end
            value = point.to_s
            unless POINTS.include?(value)
              fail_control!("selector stopper point is invalid")
            end
            value.freeze
          end

          def validate_hook!(point, metadata)
            SQLiteSelectorControl.send(
              :validate_registry_unchanged!,
              @registry,
              @expectation.registry_reference
            )
            @registry.validate_hook!(point, metadata)
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new(
              "selector stopper hook is invalid: #{error.class}"
            ), cause: error
          end

          def write_control!
            SQLiteSelectorControl.send(:validate_layout!, @layout)
            flags = File::WRONLY | File::CREAT | File::EXCL
            flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
            written_stat = nil

            File.open(@layout.path, flags, 0o600) do |control|
              control.chmod(0o600)
              validate_control_stat!(control.stat, expected_size: 0)
              written = control.write(@expectation.bytes)
              unless written == @expectation.bytes.bytesize
                raise ExecutionError, "selector control write was incomplete"
              end
              control.flush
              control.fsync
              written_stat = control.stat
              validate_control_stat!(
                written_stat,
                expected_size: @expectation.bytes.bytesize
              )
            end
            SQLiteSelectorControl.send(:sync_directory, @layout.directory)
            SQLiteSelectorControl.send(:validate_layout!, @layout)

            stat = File.lstat(@layout.path)
            validate_control_stat!(
              stat,
              expected_size: @expectation.bytes.bytesize
            )
            unless stat.dev == written_stat.dev && stat.ino == written_stat.ino
              raise ExecutionError,
                    "selector control path changed after persistence"
            end
          rescue Errno::EEXIST
            raise ExecutionError, "selector control file already exists"
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new(
              "cannot persist selector control: #{error.class}"
            ), cause: error
          end

          def validate_control_stat!(stat, expected_size:)
            unless stat.file? &&
                   stat.uid == Process.euid &&
                   stat.dev == @layout.device &&
                   stat.nlink == 1 &&
                   (stat.mode & 0o7777) == 0o600
              raise ExecutionError,
                    "selector control file identity or mode is invalid"
            end
            if expected_size && stat.size != expected_size
              raise ExecutionError, "selector control file size changed"
            end
          end

          def fail_control!(message)
            @state = :failed
            raise ExecutionError, message
          end
        end

        private_constant :Stopper
      end
    end
  end
end
