# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'thread'

module Tamoz
  module Observability
    module Recorder
      class Null
        INSTANCE = new.freeze

        def record(_signal) = :dropped

        def health
          {
            'enabled' => false,
            'reserved_depth' => 0,
            'bulk_depth' => 0,
            'drops' => {},
            'journal_disabled' => false
          }
        end

        def flush(deadline_ms:) = 0
        def close = nil
      end

      class Memory
        attr_reader :signals

        def initialize(max_size: 1_024, catalog: Catalog, strict: false, policy_digest: nil)
          @max_size = Integer(max_size)
          raise ValidationError, 'max_size must be positive' unless @max_size.positive?
          @catalog = catalog
          @strict = strict
          @policy_digest = policy_digest
          @signals = []
          @drops = Hash.new(0)
          @mutex = Mutex.new
        end

        def record(signal)
          validate!(signal)
          @mutex.synchronize do
            if @signals.length >= @max_size
              @drops[[signal.name, 'queue_full', 'bulk']] += 1
              return :dropped
            end

            @signals << signal
            :recorded
          end
        rescue StandardError
          raise if @strict

          @mutex.synchronize { @drops[['invalid', 'validation', 'bulk']] += 1 }
          :dropped
        end

        def health
          @mutex.synchronize do
            {
              'enabled' => true,
              'reserved_depth' => 0,
              'bulk_depth' => @signals.length,
              'drops' => drops_hash,
              'journal_disabled' => false,
              'policy_digest' => @policy_digest
            }
          end
        end

        def flush(deadline_ms:) = 0
        def close = nil

        private

        def validate!(signal)
          raise ValidationError, 'record expects a Signal' unless signal.is_a?(Signal)

          @catalog.validate_signal(signal)
        end

        def drops_hash
          @drops.to_h { |(name, reason, lane), count| ["#{name}:#{reason}:#{lane}", count] }
        end
      end

      class Fanout
        def initialize(recorders)
          @recorders = Array(recorders).compact.freeze
        end

        def record(signal)
          results = @recorders.map { |recorder| guarded { recorder.record(signal) } }
          results.include?(:recorded) ? :recorded : :dropped
        end

        def health
          @recorders.each_with_index.to_h do |recorder, index|
            [index.to_s, guarded { recorder.health }]
          end
        end

        def flush(deadline_ms:)
          @recorders.sum { |recorder| Integer(guarded { recorder.flush(deadline_ms:) } || 0) }
        end

        def close
          @recorders.each { |recorder| guarded { recorder.close if recorder.respond_to?(:close) } }
          nil
        end

        private

        def guarded
          yield
        rescue StandardError
          :dropped
        end
      end

      class Journal
        DEFAULT_QUEUE_SIZE = 1_024
        DEFAULT_RESERVED_SIZE = 64
        DEFAULT_MAX_FILE_BYTES = 32 * 1_024 * 1_024
        DEFAULT_MAX_FILES = 8

        attr_reader :path

        def self.read(directory, role: nil, since_ms: nil, thread_id: nil, kind: nil)
          read_entries(directory, role:, since_ms:, thread_id:, kind:).map(&:first)
        end

        def self.read_entries(directory, role: nil, since_ms: nil, thread_id: nil, kind: nil)
          files = Dir.glob(File.join(File.expand_path(directory), "#{role || '*'}-*.ndjson*"))
                       .reject { |file| file.end_with?('.health.json') }
          files.sort.flat_map do |file|
            begin
              identity = begin
                stat = File.stat(file)
                "#{stat.dev}:#{stat.ino}"
              end
              File.foreach(file, encoding: Encoding::UTF_8).with_index.filter_map do |line, index|
                next if line.strip.empty?

                document = JSON.parse(line)
                next if since_ms && document.fetch('observed_at_ms', 0) < since_ms
                next if thread_id && document.dig('correlation', 'thread_id') != thread_id
                next if kind && document.fetch('kind') != kind.to_s

                [document, "#{identity}:#{index}"]
              rescue JSON::ParserError
                nil
              end
            rescue Errno::ENOENT
              []
            end
          end.sort_by { |document, _identity| document.fetch('observed_at_ms', 0) }
        end

        def self.inventory(directory)
          files = Dir.glob(File.join(File.expand_path(directory), '*.ndjson*')).reject { |file| file.end_with?('.health.json') }
          health_files = Dir.glob(File.join(File.expand_path(directory), '*.health.json'))
          drops = health_files.sum do |file|
            JSON.parse(File.read(file)).fetch('drops', {}).values.sum
          rescue JSON::ParserError, SystemCallError
            0
          end
          {
            'files' => files.length,
            'bytes' => files.sum { |file| File.size(file) },
            'drops' => drops,
            'paths' => files.sort
          }
        rescue Errno::ENOENT
          {'files' => 0, 'bytes' => 0, 'drops' => 0, 'paths' => []}
        end

        def initialize(directory:, role:, pid: Process.pid, catalog: Catalog, policy: ContentPolicy::NONE,
                       queue_size: DEFAULT_QUEUE_SIZE, reserved_size: DEFAULT_RESERVED_SIZE,
                       max_file_bytes: DEFAULT_MAX_FILE_BYTES, max_files: DEFAULT_MAX_FILES,
                       flush_interval_ms: 200, strict: false)
          @directory = File.expand_path(directory)
          @role = String(role).gsub(/[^a-zA-Z0-9_.-]/, '_')
          @path = File.join(@directory, "#{@role}-#{Integer(pid)}.ndjson")
          @health_path = "#{@path}.health.json"
          @catalog = catalog
          @policy_digest = policy.digest
          @queue_size = positive_integer(queue_size, :queue_size)
          @reserved_size = positive_integer(reserved_size, :reserved_size)
          @max_file_bytes = positive_integer(max_file_bytes, :max_file_bytes)
          @max_files = positive_integer(max_files, :max_files)
          @flush_interval = Float(flush_interval_ms) / 1_000
          @strict = strict
          @reserved = []
          @bulk = []
          @drops = Hash.new(0)
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @closed = false
          @disabled = false
          @in_flight = 0
          @io = nil
          @io_bytes = 0
          FileUtils.mkdir_p(@directory, mode: 0o700)
          File.chmod(0o700, @directory)
          @thread = Thread.new { drain }
        end

        def record(signal)
          validate!(signal)
          reserved = @catalog.safety_bearing?(signal.name)
          @mutex.synchronize do
            if @closed || @disabled
              @drops[[signal.name, @closed ? 'closed' : 'disabled', reserved ? 'reserved' : 'bulk']] += 1
              persist_health
              return :dropped
            end

            queue = reserved ? @reserved : @bulk
            limit = reserved ? @reserved_size : @queue_size
            if queue.length < limit
              queue << signal
              @condition.signal
              return :recorded
            end

            if reserved
              # Safety-bearing evidence is never dropped. The fallback is a
              # single bounded local write; it never contacts a collector.
              write_now(signal) ? :recorded : :dropped
            else
              @drops[[signal.name, 'queue_full', 'bulk']] += 1
              persist_health
              :dropped
            end
          end
        rescue StandardError
          raise if @strict

          @mutex.synchronize { @drops[['invalid', 'validation', 'bulk']] += 1 }
          :dropped
        end

        def health
          @mutex.synchronize do
            {
              'enabled' => true,
              'reserved_depth' => @reserved.length,
              'bulk_depth' => @bulk.length,
              'drops' => drops_hash,
              'journal_disabled' => @disabled,
              'path' => path,
              'policy_digest' => @policy_digest
            }
          end
        end

        def flush(deadline_ms:)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(deadline_ms) / 1_000
          @mutex.synchronize do
            while @reserved.any? || @bulk.any? || @in_flight.positive?
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              break if remaining <= 0

              @condition.wait(@mutex, remaining)
            end
            @reserved.length + @bulk.length + @in_flight
          end
        end

        def close
          @mutex.synchronize do
            return if @closed

            @closed = true
            @condition.broadcast
          end
          @thread.join(1.0)
          nil
        end

        private

        def positive_integer(value, name)
          return value if value.is_a?(Integer) && value.positive?

          raise ValidationError, "#{name} must be a positive integer"
        end

        def validate!(signal)
          raise ValidationError, 'record expects a Signal' unless signal.is_a?(Signal)

          @catalog.validate_signal(signal)
        end

        def drain
          loop do
            batch = @mutex.synchronize do
              while @reserved.empty? && @bulk.empty? && !@closed
                @condition.wait(@mutex, @flush_interval)
              end
              next if @closed && @reserved.empty? && @bulk.empty?

              values = @reserved.shift(@reserved_size) + @bulk.shift(@queue_size)
              @in_flight += values.length
              values
            end
            break unless batch
            write_batch(batch)
          end
        rescue StandardError
          @mutex.synchronize { disable!('writer_failure') }
        ensure
          @mutex.synchronize { close_io }
        end

        def write_batch(batch)
          batch.each { |signal| write_signal(signal) }
        ensure
          @mutex.synchronize do
            @in_flight -= batch.length if batch
            @condition.broadcast
          end
        end

        def write_now(signal)
          write_signal(signal)
        rescue StandardError
          disable!('disk_error')
          false
        end

        def write_signal(signal)
          return false if @disabled

          line = JSON.generate(signal.to_h.merge('policy_digest' => signal.policy_digest || @policy_digest))
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
          current_bytes = @io ? @io_bytes : (File.file?(path) ? File.size(path) : 0)
          return unless current_bytes.positive? && current_bytes + incoming_bytes > @max_file_bytes

          close_io
          if @max_files == 1
            File.delete(path) if File.exist?(path)
          else
            (@max_files - 1).downto(1) do |index|
              source = index == 1 ? path : "#{path}.#{index - 1}"
              target = "#{path}.#{index}"
              File.delete(target) if File.exist?(target)
              File.rename(source, target) if File.exist?(source)
            end
          end
          @io_bytes = 0
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
          @drops[['journal', reason, 'bulk']] += 1
          persist_health
          close_io
        end

        def persist_health
          File.write(@health_path, JSON.generate('drops' => drops_hash), mode: 'w', perm: 0o600)
        rescue SystemCallError
          nil
        end

        def drops_hash
          @drops.to_h { |(name, reason, lane), count| ["#{name}:#{reason}:#{lane}", count] }
        end
      end
    end
  end
end
