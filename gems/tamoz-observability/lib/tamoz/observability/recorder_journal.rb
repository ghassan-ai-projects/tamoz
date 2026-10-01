# frozen_string_literal: true

require 'fileutils'
require 'json'

module Tamoz
  module Observability
    module Recorder
      # The disk journal over the shared Concurrency::Drain skeleton. What
      # stays here is this recorder's own policy: the reserved lane never
      # drops (a full reserved queue falls back to a single bounded local
      # write inside #record), rotation and strict mode, and the drop ledger.
      class Journal < Concurrency::Drain
        include DropLedger

        DEFAULT_QUEUE_SIZE = 1_024
        DEFAULT_RESERVED_SIZE = 64
        DEFAULT_MAX_FILE_BYTES = 32 * 1_024 * 1_024
        DEFAULT_MAX_FILES = 8

        attr_reader :path

        def self.read(directory, role: nil, since_ms: nil, thread_id: nil, kind: nil)
          Files.read(directory, role:, since_ms:, thread_id:, kind:)
        end

        def self.read_entries(directory, role: nil, since_ms: nil, thread_id: nil, kind: nil)
          Files.read_entries(directory, role:, since_ms:, thread_id:, kind:)
        end

        def self.inventory(directory)
          Files.inventory(directory)
        end

        def initialize(directory:, role:, pid: Process.pid, catalog: Catalog, policy: ContentPolicy::NONE,
                       queue_size: DEFAULT_QUEUE_SIZE, reserved_size: DEFAULT_RESERVED_SIZE,
                       max_file_bytes: DEFAULT_MAX_FILE_BYTES, max_files: DEFAULT_MAX_FILES,
                       flush_interval_ms: 200, strict: false)
          resolve_journal_paths(directory:, role:, pid:)
          @catalog = catalog
          @policy_digest = policy.digest
          @queue_size = positive_integer(queue_size, :queue_size)
          @reserved_size = positive_integer(reserved_size, :reserved_size)
          @max_file_bytes = positive_integer(max_file_bytes, :max_file_bytes)
          @max_files = positive_integer(max_files, :max_files)
          @flush_interval = Float(flush_interval_ms) / 1_000
          @strict = strict
          @drops = Hash.new(0)
          @io = nil
          @io_bytes = 0
          prepare_directory(@directory)
          super(lanes: { reserved: @reserved_size, bulk: @queue_size },
                batch_size: @queue_size + @reserved_size,
                interval: @flush_interval)
        end

        def record(signal) = guard_record(signal) { route(signal) }

        def health
          synchronize do
            {
              'enabled' => true,
              'reserved_depth' => lane_depths.fetch(:reserved),
              'bulk_depth' => lane_depths.fetch(:bulk),
              'drops' => drops_hash,
              'journal_disabled' => drain_disabled?,
              'path' => path,
              'policy_digest' => @policy_digest
            }
          end
        end

        private

        def positive_integer(value, name)
          return value if value.is_a?(Integer) && value.positive?

          raise ValidationError, "#{name} must be a positive integer"
        end

        def route(signal)
          lane = reserved?(signal) ? :reserved : :bulk
          synchronize { accept_or_drop(signal, lane) }
        end

        def reserved?(signal)
          @catalog.safety_bearing?(signal.name)
        end

        def accept_or_drop(signal, lane)
          return drop_drain_closed(signal, lane) if drain_closed?
          return drop_drain_disabled(signal, lane) if drain_disabled?
          return :recorded if accept(lane, signal)
          return write_reserved_now(signal) if lane == :reserved

          drop_queue_full(signal)
        end

        def drop_drain_closed(signal, lane)
          drop_signal(signal.name, 'closed', lane)
        end

        def drop_drain_disabled(signal, lane)
          drop_signal(signal.name, 'disabled', lane)
        end

        def drop_queue_full(signal)
          drop_signal(signal.name, 'queue_full', 'bulk')
        end

        def drop_signal(name, reason, lane)
          @drops[drop_key(name, reason, lane)] += 1
          persist_health
          :dropped
        end

        def write_reserved_now(signal)
          write_signal(signal) ? :recorded : :dropped
        rescue StandardError
          disable!('disk_error')
          :dropped
        end

        def compose_batch
          shift_lane(:reserved, @reserved_size) + shift_lane(:bulk, @queue_size)
        end

        def deliver_batch(batch)
          batch.each { |signal| write_signal(signal) }
        end

        def handle_loop_error(_error)
          synchronize { disable!('writer_failure') }
        end

        def on_thread_exit
          synchronize { close_io }
        end

        def write_signal(signal)
          return false if @disabled

          append_line(render_line(signal))
        end

        def render_line(signal)
          JSON.generate(signal.to_h.merge('policy_digest' => signal.policy_digest || @policy_digest))
        end

        def append_line(line)
          rotate_if_needed(line.bytesize + 1)
          open_io
          @io.write("#{line}\n")
          @io.flush
          @io_bytes += line.bytesize + 1
          true
        rescue SystemCallError
          disable!('disk_error')
          false
        end

        def rotate_if_needed(incoming_bytes)
          return unless rotation_needed?(incoming_bytes)

          close_io
          rotate_files
          @io_bytes = 0
        end

        def rotation_needed?(incoming_bytes)
          current_file_bytes.positive? && current_file_bytes + incoming_bytes > @max_file_bytes
        end

        def current_file_bytes
          @io ? @io_bytes : (File.file?(path) ? File.size(path) : 0)
        end

        def rotate_files
          if @max_files == 1
            delete_current_file
          else
            shift_numbered_backups
          end
        end

        def delete_current_file
          File.delete(path) if File.exist?(path)
        end

        def shift_numbered_backups
          (@max_files - 1).downto(1) do |index|
            source = index == 1 ? path : "#{path}.#{index - 1}"
            target = "#{path}.#{index}"
            File.delete(target) if File.exist?(target)
            File.rename(source, target) if File.exist?(source)
          end
        end

        def open_io
          return if @io

          @io_bytes = File.file?(path) ? File.size(path) : 0
          @io = File.open(path, 'ab', 0o600)
          File.chmod(0o600, path)
        end

        def close_io
          @io&.close
          @io = nil
          @io_bytes = 0
        end

        def disable!(reason)
          @disabled = true
          @drops[drop_key('journal', reason, 'bulk')] += 1
          persist_health
          close_io
        end

        def persist_health
          File.write(@health_path, JSON.generate('drops' => drops_hash), mode: 'w', perm: 0o600)
        rescue SystemCallError
          nil
        end

        def normalize_role(role)
          String(role).gsub(/[^a-zA-Z0-9_.-]/, '_')
        end

        def resolve_journal_paths(directory:, role:, pid:)
          @directory = File.expand_path(directory)
          @role = normalize_role(role)
          @path = File.join(@directory, "#{@role}-#{Integer(pid)}.ndjson")
          @health_path = "#{@path}.health.json"
        end

        def prepare_directory(directory)
          FileUtils.mkdir_p(directory, mode: 0o700)
          File.chmod(0o700, directory)
        end

        # File-system reads and inventory are stateless queries over the journal
        # directory. They live next to Journal because they interpret its file
        # naming and sidecar conventions, but they need no instance state.
        class Files
          def self.read(directory, role: nil, since_ms: nil, thread_id: nil, kind: nil)
            read_entries(directory, role:, since_ms:, thread_id:, kind:).map(&:first)
          end

          def self.read_entries(directory, role: nil, since_ms: nil, thread_id: nil, kind: nil)
            matching_files(directory, role)
              .flat_map { |file| read_file_entries(file, since_ms:, thread_id:, kind:) }
              .sort_by { |document, _identity| document.fetch('observed_at_ms', 0) }
          end

          def self.inventory(directory)
            ndjson_files, health_files = inventory_files(directory)
            build_inventory(ndjson_files, health_files)
          rescue Errno::ENOENT
            empty_inventory
          end

          def self.matching_files(directory, role)
            Dir.glob(File.join(File.expand_path(directory), "#{role || '*'}-*.ndjson*"))
               .reject { |file| file.end_with?('.health.json') }
               .sort
          end
          private_class_method :matching_files

          def self.read_file_entries(file, since_ms:, thread_id:, kind:)
            identity = file_identity(file)
            File.foreach(file, encoding: Encoding::UTF_8).with_index.filter_map do |line, index|
              parse_entry(line, identity, index, since_ms:, thread_id:, kind:)
            end
          rescue Errno::ENOENT
            []
          end
          private_class_method :read_file_entries

          def self.file_identity(file)
            stat = File.stat(file)
            "#{stat.dev}:#{stat.ino}"
          end
          private_class_method :file_identity

          def self.parse_entry(line, file_identity, index, since_ms:, thread_id:, kind:)
            return nil if line.strip.empty?

            document = JSON.parse(line)
            return nil unless matches_filters?(document, since_ms:, thread_id:, kind:)

            [document, "#{file_identity}:#{index}"]
          rescue JSON::ParserError
            nil
          end
          private_class_method :parse_entry

          def self.matches_filters?(document, since_ms:, thread_id:, kind:)
            return false if since_ms && document.fetch('observed_at_ms', 0) < since_ms
            return false if thread_id && document.dig('correlation', 'thread_id') != thread_id
            return false if kind && document.fetch('kind') != kind.to_s

            true
          end
          private_class_method :matches_filters?

          def self.inventory_files(directory)
            expanded = File.expand_path(directory)
            ndjson_files = Dir.glob(File.join(expanded, '*.ndjson*')).reject { |file| file.end_with?('.health.json') }
            health_files = Dir.glob(File.join(expanded, '*.health.json'))
            [ndjson_files, health_files]
          end
          private_class_method :inventory_files

          def self.build_inventory(ndjson_files, health_files)
            {
              'files' => ndjson_files.length,
              'bytes' => ndjson_files.sum { |file| File.size(file) },
              'drops' => health_files.sum { |file| drops_from_health_file(file) },
              'paths' => ndjson_files.sort
            }
          end
          private_class_method :build_inventory

          def self.drops_from_health_file(file)
            JSON.parse(File.read(file)).fetch('drops', {}).values.sum
          rescue JSON::ParserError, SystemCallError
            0
          end
          private_class_method :drops_from_health_file

          def self.empty_inventory
            {'files' => 0, 'bytes' => 0, 'drops' => 0, 'paths' => []}
          end
          private_class_method :empty_inventory
        end
      end
    end
  end
end
