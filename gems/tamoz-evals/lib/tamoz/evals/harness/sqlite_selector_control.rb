# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteSelectorControl
        VERSION = 1
        MAX_CONTROL_BYTES = 64 * 1024
        MAX_ID_BYTES = 128
        MAX_OCCURRENCE = 256
        MAX_REMAINING_MS = 3_600_000
        CONTROL_FILENAME = "selector-control.json"
        ID_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
        POINTS = %w[
          before_begin after_begin before_sql after_sql before_commit after_commit
        ].freeze
        SELECTOR_FIELDS = %w[
          scenario point operation statement attempt_class occurrence
          iteration_class selector_digest
        ].freeze
        SCENARIO_FIELDS = %w[id version digest].freeze
        REGISTRY_FIELDS = %w[version digest].freeze
        ITERATION_CLASSES = %w[single first middle final].freeze
        RECORD_FIELDS = %w[
          control_version control_digest scenario registry selector observed_hook
          content_digest
        ].freeze
        OBSERVED_HOOK_FIELDS = %w[
          point hook_version kind operation statement attempt occurrence
        ].freeze
        DEFINITION = DeepFreeze.call(
          {
            "id" => "tamoz.sqlite.selector_control",
            "version" => VERSION,
            "limits" => {
              "control_bytes" => MAX_CONTROL_BYTES,
              "occurrences" => MAX_OCCURRENCE,
              "remaining_ms" => MAX_REMAINING_MS,
              "id_bytes" => MAX_ID_BYTES
            },
            "record_fields" => RECORD_FIELDS,
            "scenario_fields" => SCENARIO_FIELDS,
            "registry_fields" => REGISTRY_FIELDS,
            "selector_fields" => SELECTOR_FIELDS,
            "observed_hook_fields" => OBSERVED_HOOK_FIELDS,
            "directory_policy" =>
              "same-filesystem-owned-0700-pinned-device-inode",
            "creation_policy" =>
              "owned-0600-regular-single-link-exclusive-" \
              "nofollow-when-available-lstat-fstat",
            "persistence_policy" =>
              "canonical-json-newline-file-fsync-directory-fsync",
            "child_policy" =>
              "post-spawn-owner-thread-exact-occurrence-then-sigstop",
            "parent_policy" =>
              "wuntraced-exact-sigstop-stable-read-post-kill-reread",
            "decision_policy" => "nil-or-kill-before-monotonic-deadline",
            "result_policy" =>
              "exact-immutable-subprocess-result-kill-intervention-" \
              "kill-signal-not-timeout-no-exit-status",
            "content_digest_domain" => "eval.sqlite_selector_control",
            "selector_digest_domain" => "eval.sqlite_selector"
          }
        )
        DEFINITION_DIGEST = CanonicalJSON.content_digest(
          DEFINITION,
          domain: "eval.sqlite_selector_control_definition"
        ).freeze

        Layout = Data.define(:directory, :device, :inode) do
          def path
            File.join(directory, CONTROL_FILENAME).freeze
          end

          def descriptor
            DeepFreeze.call(
              {
                "directory" => directory,
                "device" => device,
                "inode" => inode
              }
            )
          end
        end

        Expectation = Data.define(
          :scenario,
          :selector,
          :registry_reference,
          :hook,
          :record,
          :bytes
        )

        class << self
          def definition
            DEFINITION
          end

          def digest
            DEFINITION_DIGEST
          end

          def prepare!(root:, name:, filesystem_anchor:)
            directory = nil
            created = false
            root_path, root_stat = private_directory(root, name: "control root")
            anchor_stat = filesystem_anchor_stat(filesystem_anchor)
            unless root_stat.dev == anchor_stat.dev
              raise ExecutionError,
                    "control root and filesystem anchor must share a filesystem"
            end

            directory_name = validate_identifier(
              name,
              name: "control directory name",
              maximum: 64
            )
            directory = create_control_directory!(
              root_path: root_path,
              directory_name: directory_name
            )
            created = true
            layout = layout_from_path(directory)
            ensure_control_absent!(layout)
            layout
          rescue ExecutionError
            remove_empty_directory(directory) if created
            raise
          rescue StandardError => error
            remove_empty_directory(directory) if created
            raise ExecutionError.new(
              "cannot prepare SQLite selector control: #{error.class}"
            ), cause: error
          end

          def create_control_directory!(root_path:, directory_name:)
            directory = File.join(root_path, directory_name)
            if lstat_if_present(directory)
              raise ExecutionError, "control directory must not pre-exist"
            end

            created = false
            begin
              Dir.mkdir(directory, 0o700)
              created = true
              File.chmod(0o700, directory)
              sync_directory(root_path)
            rescue StandardError
              remove_empty_directory(directory) if created
              raise
            end
            directory
          end

          def attach!(directory:, device:, inode:)
            expected_device = validate_nonnegative_integer(
              device,
              name: "control directory device"
            )
            expected_inode = validate_positive_integer(
              inode,
              name: "control directory inode",
              maximum: (2**63) - 1
            )
            path, stat = private_directory(
              directory,
              name: "control directory"
            )
            unless stat.dev == expected_device && stat.ino == expected_inode
              raise ExecutionError, "control directory identity changed"
            end

            Layout.new(
              directory: path,
              device: stat.dev,
              inode: stat.ino
            ).freeze
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new(
              "cannot attach SQLite selector control: #{error.class}"
            ), cause: error
          end

          def stopper(layout:, scenario:, selector:, registry:)
            Stopper.new(layout:, scenario:, selector:, registry:)
          end

          def intervention(layout:, scenario:, selector:, registry:)
            Intervention.new(layout:, scenario:, selector:, registry:)
          end

          private

          def build_expectation(scenario:, selector:, registry:)
            registry_reference = normalize_registry_reference(registry)
            scenario_value = normalize_scenario(scenario)
            selector_value = normalize_selector(
              selector,
              scenario: scenario_value,
              registry:
            )
            hook = build_expected_hook(
              selector_value,
              hook_version: registry_reference.fetch("version")
            )
            validate_registry_hook!(registry, selector_value.fetch("point"), hook)

            record, bytes = build_control_record(
              scenario: scenario_value,
              selector: selector_value,
              registry_reference: registry_reference,
              hook: hook
            )
            Expectation.new(
              scenario: scenario_value,
              selector: selector_value,
              registry_reference: registry_reference,
              hook: hook,
              record: record,
              bytes: bytes
            ).freeze
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new(
              "invalid SQLite selector control expectation: #{error.class}"
            ), cause: error
          end

          def build_control_record(scenario:, selector:, registry_reference:, hook:)
            body = {
              "control_version" => VERSION,
              "control_digest" => DEFINITION_DIGEST,
              "scenario" => scenario,
              "registry" => registry_reference,
              "selector" => selector,
              "observed_hook" => hook
            }
            body["content_digest"] = CanonicalJSON.content_digest(
              body,
              domain: "eval.sqlite_selector_control"
            )
            record = DeepFreeze.call(body)
            bytes = "#{CanonicalJSON.dump(record)}\n".freeze
            if bytes.bytesize > MAX_CONTROL_BYTES
              raise ExecutionError,
                    "SQLite selector control exceeds #{MAX_CONTROL_BYTES} bytes"
            end

            [record, bytes]
          end

          def normalize_scenario(value)
            object = validate_exact_hash(value, SCENARIO_FIELDS, name: "control scenario")
            DeepFreeze.call(
              {
                "id" => validate_identifier(
                  object.fetch("id"),
                  name: "control scenario id",
                  maximum: MAX_ID_BYTES
                ),
                "version" => validate_positive_integer(
                  object.fetch("version"),
                  name: "control scenario version",
                  maximum: 1_000_000
                ),
                "digest" => validate_digest(
                  object.fetch("digest"),
                  name: "control scenario digest"
                )
              }
            )
          end

          def normalize_selector(value, scenario:, registry:)
            object = validate_exact_hash(value, SELECTOR_FIELDS, name: "control selector")
            point = selector_point(object)
            operation = enforce_phase2_operation!(object, registry)
            statement = optional_statement(object)
            enforce_selector_binding!(object, scenario:)
            occurrence = validate_positive_integer(
              object.fetch("occurrence"),
              name: "control selector occurrence",
              maximum: MAX_OCCURRENCE
            )
            iteration_class = iteration_class_value(object)
            selector_digest = validate_digest(
              object.fetch("selector_digest"),
              name: "control selector digest"
            )

            body = {
              "scenario" => scenario.fetch("id").dup.freeze,
              "point" => point,
              "operation" => operation,
              "statement" => statement,
              "attempt_class" => "first".freeze,
              "occurrence" => occurrence,
              "iteration_class" => iteration_class.dup.freeze
            }
            verify_selector_digest!(body, claimed: selector_digest)
            body["selector_digest"] = selector_digest
            DeepFreeze.call(body)
          end

          def selector_point(object)
            point = validate_identifier(
              object.fetch("point"),
              name: "control selector point",
              maximum: MAX_ID_BYTES
            )
            unless POINTS.include?(point)
              raise ExecutionError, "control selector point is invalid"
            end
            point
          end

          def enforce_phase2_operation!(object, registry)
            operation = validate_identifier(
              object.fetch("operation"),
              name: "control selector operation",
              maximum: MAX_ID_BYTES
            )
            operation_entry = registry.operation(operation)
            unless operation_entry &&
                   operation_entry.fetch("phase") == 2 &&
                   operation_entry.fetch("kill_required") == true
              raise ExecutionError,
                    "control selector operation is not Phase 2 kill-required"
            end
            operation
          end

          def optional_statement(object)
            statement = object.fetch("statement")
            return nil if statement.nil?

            validate_identifier(
              statement,
              name: "control selector statement",
              maximum: MAX_ID_BYTES
            )
          end

          def enforce_selector_binding!(object, scenario:)
            unless object.fetch("scenario") == scenario.fetch("id")
              raise ExecutionError,
                    "control selector scenario does not match its scenario"
            end
            unless object.fetch("attempt_class") == "first"
              raise ExecutionError,
                    "Phase 2 control selectors require the first attempt"
            end
          end

          def iteration_class_value(object)
            iteration_class = object.fetch("iteration_class")
            unless iteration_class.is_a?(String) &&
                   ITERATION_CLASSES.include?(iteration_class)
              raise ExecutionError,
                    "control selector iteration class is invalid"
            end
            iteration_class
          end

          def verify_selector_digest!(body, claimed:)
            expected_digest = CanonicalJSON.content_digest(
              body,
              domain: "eval.sqlite_selector"
            )
            return true if claimed == expected_digest

            raise ExecutionError, "control selector digest is invalid"
          end

          def build_expected_hook(selector, hook_version:)
            point = selector.fetch("point")
            kind = %w[before_sql after_sql].include?(point) ? "statement" : "transaction"
            DeepFreeze.call(
              {
                "point" => point.dup.freeze,
                "hook_version" => hook_version,
                "kind" => kind.freeze,
                "operation" => selector.fetch("operation").dup.freeze,
                "statement" => selector.fetch("statement")&.dup&.freeze,
                "attempt" => 1,
                "occurrence" => selector.fetch("occurrence")
              }
            )
          end

          def normalize_registry_reference(registry)
            required = %i[digest document operation validate_hook!]
            unless required.all? { |method| registry.respond_to?(method) }
              raise ExecutionError,
                    "SQLite boundary registry contract is invalid"
            end
            document = registry.document
            unless document.is_a?(Hash) && deeply_frozen?(document)
              raise ExecutionError,
                    "SQLite boundary registry document must be deeply frozen"
            end

            DeepFreeze.call(
              {
                "version" => validate_positive_integer(
                  document.fetch("registry_version"),
                  name: "control registry version",
                  maximum: 1_000_000
                ),
                "digest" => validate_digest(
                  registry.digest,
                  name: "control registry digest"
                )
              }
            )
          end

          def validate_registry_unchanged!(registry, reference)
            unless normalize_registry_reference(registry) == reference
              raise ExecutionError,
                    "SQLite boundary registry changed during selector control"
            end
          end

          def preflight_record!(record)
            validate_exact_hash(record, RECORD_FIELDS, name: "selector control record")
            unless record.fetch("control_version") == VERSION &&
                   record.fetch("control_digest") == DEFINITION_DIGEST
              raise ExecutionError,
                    "selector control protocol identity is invalid"
            end
            validate_exact_hash(
              record.fetch("scenario"),
              SCENARIO_FIELDS,
              name: "selector control scenario"
            )
            validate_exact_hash(
              record.fetch("registry"),
              REGISTRY_FIELDS,
              name: "selector control registry"
            )
            validate_exact_hash(
              record.fetch("selector"),
              SELECTOR_FIELDS,
              name: "selector control selector"
            )
            validate_exact_hash(
              record.fetch("observed_hook"),
              OBSERVED_HOOK_FIELDS,
              name: "selector control observed hook"
            )
            validate_digest(
              record.fetch("content_digest"),
              name: "selector control content digest"
            )
            true
          end

          def validate_registry_hook!(registry, point, hook)
            metadata = DeepFreeze.call(
              {
                "hook_version" => hook.fetch("hook_version"),
                "kind" => hook.fetch("kind").dup.freeze,
                "operation" => hook.fetch("operation").dup.freeze,
                "statement" => hook.fetch("statement")&.dup&.freeze,
                "attempt" => hook.fetch("attempt")
              }
            )
            registry.validate_hook!(point, metadata)
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new(
              "SQLite selector hook is absent from the registry: #{error.class}"
            ), cause: error
          end

          def validate_layout!(layout)
            unless layout.instance_of?(Layout) &&
                   layout.frozen? &&
                   layout.directory.is_a?(String) &&
                   layout.directory.frozen? &&
                   layout.device.is_a?(Integer) &&
                   layout.inode.is_a?(Integer)
              raise ExecutionError, "control layout is invalid"
            end
            path, stat = private_directory(
              layout.directory,
              name: "control directory"
            )
            unless path == layout.directory &&
                   stat.dev == layout.device &&
                   stat.ino == layout.inode
              raise ExecutionError, "control directory identity changed"
            end

            stat
          end

          def ensure_control_absent!(layout)
            validate_layout!(layout)
            if lstat_if_present(layout.path)
              raise ExecutionError, "selector control file must be absent"
            end
            true
          end

          def resolve_real_path(value, name:)
            raw = File.path(value)
            raise ExecutionError, "#{name} contains a NUL byte" if raw.include?("\0")

            expanded = File.expand_path(raw)
            if File.lstat(expanded).symlink?
              raise ExecutionError, "#{name} must not be a symlink"
            end
            File.realpath(expanded).freeze
          end

          def private_directory(value, name:)
            real = resolve_real_path(value, name: name)
            stat = File.stat(real)
            unless stat.directory? &&
                   stat.uid == Process.euid &&
                   (stat.mode & 0o7777) == 0o700
              raise ExecutionError,
                    "#{name} must be an owned private 0700 directory"
            end

            [real, stat]
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new("#{name} is invalid: #{error.class}"), cause: error
          end

          def filesystem_anchor_stat(value)
            real = resolve_real_path(value, name: "filesystem anchor")
            File.stat(real)
          rescue ExecutionError
            raise
          rescue StandardError => error
            raise ExecutionError.new(
              "filesystem anchor is invalid: #{error.class}"
            ), cause: error
          end

          def layout_from_path(directory)
            path, stat = private_directory(
              directory,
              name: "control directory"
            )
            Layout.new(
              directory: path,
              device: stat.dev,
              inode: stat.ino
            ).freeze
          end

          def sync_directory(path)
            File.open(path, File::RDONLY) do |directory|
              directory.fsync
            end
          end

          def lstat_if_present(path)
            File.lstat(path)
          rescue Errno::ENOENT
            nil
          end

          def remove_empty_directory(path)
            return unless path

            Dir.rmdir(path)
          rescue SystemCallError
            nil
          end

          def validate_exact_hash(value, fields, name:)
            unless value.is_a?(Hash) &&
                   value.length == fields.length &&
                   fields.all? { |field| value.key?(field) }
              raise ExecutionError, "#{name} shape is invalid"
            end
            value
          end

          def validate_identifier(value, name:, maximum:)
            unless value.is_a?(String) &&
                   value.valid_encoding? &&
                   !value.empty? &&
                   value.bytesize <= maximum &&
                   value.match?(ID_PATTERN)
              raise ExecutionError, "#{name} is invalid"
            end
            value.dup.freeze
          end

          def validate_digest(value, name:)
            unless value.is_a?(String) &&
                   value.valid_encoding? &&
                   Tamoz::Core.valid_digest?(value)
              raise ExecutionError, "#{name} is invalid"
            end
            value.dup.freeze
          end

          def validate_positive_integer(value, name:, maximum:)
            return value if value.is_a?(Integer) &&
                            value.positive? &&
                            value <= maximum

            raise ExecutionError, "#{name} is invalid"
          end

          def validate_nonnegative_integer(value, name:)
            return value if value.is_a?(Integer) && value >= 0

            raise ExecutionError, "#{name} is invalid"
          end

          def deeply_frozen?(value)
            return false unless value.frozen?

            case value
            when Hash
              value.all? do |key, entry|
                deeply_frozen?(key) && deeply_frozen?(entry)
              end
            when Array
              value.all? { |entry| deeply_frozen?(entry) }
            else
              true
            end
          end
        end
      end
    end
  end
end
