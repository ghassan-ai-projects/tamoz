# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteSelectorControl
        class Intervention
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
            @state = :waiting
          end

          def poll(stop_signal:, remaining_ms:)
            ensure_owner!
            unless @state == :waiting
              raise ExecutionError, "selector intervention is not waiting"
            end
            unless stop_signal == "STOP"
              fail_control!("selector child stopped under an unexpected signal")
            end
            unless remaining_ms.is_a?(Integer) &&
                   remaining_ms.between?(0, MAX_REMAINING_MS)
              fail_control!("selector intervention remaining budget is invalid")
            end

            SQLiteSelectorControl.send(:validate_layout!, @layout)
            SQLiteSelectorControl.send(
              :validate_registry_unchanged!,
              @registry,
              @expectation.registry_reference
            )
            return nil unless File.exist?(@layout.path) ||
                              File.symlink?(@layout.path)

            bytes, control_fingerprint = read_stable_control!
            validate_control_bytes!(bytes)
            @authorized_fingerprint = control_fingerprint
            @state = :authorized
            SubprocessRunner::INTERVENTION_KILL
          rescue ExecutionError
            @state = :failed unless @state == :authorized
            raise
          rescue StandardError => error
            @state = :failed
            raise ExecutionError.new(
              "selector intervention failed: #{error.class}"
            ), cause: error
          end

          def verify_result!(result)
            ensure_owner!
            unless @state == :authorized
              raise ExecutionError,
                    "selector control was not authorized before process completion"
            end
            final_bytes, final_fingerprint = read_stable_control!
            validate_control_bytes!(final_bytes)
            unless final_fingerprint == @authorized_fingerprint
              fail_control!(
                "selector control changed after kill authorization"
              )
            end
            unless result.instance_of?(SubprocessRunner::Result) &&
                   result.frozen?
              fail_control!("selector process result contract is invalid")
            end
            unless result.termination == "kill" &&
                   result.termination_reason == "intervention" &&
                   result.term_signal == "KILL" &&
                   result.timed_out == false &&
                   result.exit_status.nil?
              fail_control!("selector process result is not an intentional SIGKILL")
            end

            @state = :verified
            true
          rescue ExecutionError
            @state = :failed unless @state == :verified
            raise
          rescue StandardError => error
            @state = :failed
            raise ExecutionError.new(
              "selector result verification failed: #{error.class}"
            ), cause: error
          end

          private

          def ensure_owner!
            unless Process.pid == @owner_process &&
                   Thread.current.equal?(@owner_thread)
              raise ExecutionError,
                    "selector intervention must remain in its parent context"
            end
          end

          def read_stable_control!
            path_stat = File.lstat(@layout.path)
            validate_control_stat!(path_stat)
            before = fingerprint(path_stat)
            flags = File::RDONLY
            flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)

            bytes = File.open(@layout.path, flags) do |control|
              opened_before = control.stat
              validate_control_stat!(opened_before)
              unless same_file?(path_stat, opened_before)
                raise ExecutionError,
                      "selector control file changed before it was opened"
              end

              content = control.read(MAX_CONTROL_BYTES + 1)
              opened_after = control.stat
              validate_control_stat!(opened_after)
              unless fingerprint(opened_before) == fingerprint(opened_after)
                raise ExecutionError,
                      "selector control file changed while it was read"
              end
              content
            end

            after_stat = File.lstat(@layout.path)
            validate_control_stat!(after_stat)
            unless before == fingerprint(after_stat)
              raise ExecutionError,
                    "selector control path changed while it was read"
            end
            if bytes.empty? || bytes.bytesize > MAX_CONTROL_BYTES
              raise ExecutionError, "selector control size is invalid"
            end

            [bytes, fingerprint(after_stat)].freeze
          rescue Errno::ELOOP
            raise ExecutionError, "selector control file must not be a symlink"
          rescue Errno::ENOENT
            raise ExecutionError, "selector control file disappeared"
          end

          def validate_control_bytes!(bytes)
            unless bytes.encoding == Encoding::BINARY || bytes.valid_encoding?
              raise ExecutionError, "selector control is not valid UTF-8"
            end
            text = bytes.dup.force_encoding(Encoding::UTF_8)
            unless text.valid_encoding?
              raise ExecutionError, "selector control is not valid UTF-8"
            end

            DuplicateKeyDetector.validate!(text)
            parsed = JSON.parse(
              text,
              create_additions: false,
              max_nesting: DuplicateKeyDetector::MAX_NESTING
            )
            SQLiteSelectorControl.send(:preflight_record!, parsed)
            unless parsed == @expectation.record
              raise ExecutionError,
                    "selector control does not match the expected record"
            end
            unless text == @expectation.bytes
              raise ExecutionError, "selector control is not canonical JSON"
            end
            expected_digest = CanonicalJSON.content_digest(
              parsed,
              domain: "eval.sqlite_selector_control"
            )
            unless parsed.fetch("content_digest") == expected_digest
              raise ExecutionError, "selector control digest is invalid"
            end

            true
          rescue JSON::ParserError => error
            raise ExecutionError.new(
              "selector control is invalid JSON: #{error.class}"
            ), cause: error
          rescue InvalidArtifactError => error
            raise ExecutionError.new(
              "selector control is invalid: #{error.class}"
            ), cause: error
          end

          def validate_control_stat!(stat)
            unless stat.file? &&
                   stat.uid == Process.euid &&
                   stat.dev == @layout.device &&
                   stat.nlink == 1 &&
                   (stat.mode & 0o7777) == 0o600 &&
                   stat.size.between?(1, MAX_CONTROL_BYTES)
              raise ExecutionError,
                    "selector control file identity, mode, or size is invalid"
            end
          end

          def fingerprint(stat)
            [
              stat.dev,
              stat.ino,
              stat.uid,
              stat.mode,
              stat.nlink,
              stat.size,
              stat.mtime.to_i,
              stat.mtime.nsec,
              stat.ctime.to_i,
              stat.ctime.nsec
            ].freeze
          end

          def same_file?(left, right)
            left.dev == right.dev && left.ino == right.ino
          end

          def fail_control!(message)
            @state = :failed
            raise ExecutionError, message
          end
        end

        private_constant :Intervention
      end

      private_constant :SQLiteSelectorControl
    end
  end
end
