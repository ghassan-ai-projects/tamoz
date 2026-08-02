# frozen_string_literal: true

require "fileutils"

module Tamoz
  module Evals
    module Harness
      # DR-3 protected partition (C7/E4). The holdout lives OUTSIDE the cell's
      # workspace root, mode 0o700, holding one record file (mode 0o600) that no
      # cell seed references. Only a distinct verifier principal reads it after
      # promotion; the read-attempt test runs the REAL runner against the REAL
      # path and asserts refusal at the OS boundary (root confinement +
      # absolute-path preflight), never a self-imposed convention check.
      class MemoryHoldout
        DIRECTORY_MODE = 0o700
        FILE_MODE = 0o600

        attr_reader :path, :record_id

        def self.create(record_id:, content:)
          directory = Dir.mktmpdir("tamoz-memory-holdout")
          File.chmod(DIRECTORY_MODE, directory)
          path = File.join(directory, "holdout.record.json")
          File.write(path, "#{CanonicalJSON.dump(content)}\n", encoding: Encoding::UTF_8)
          File.chmod(FILE_MODE, path)
          instance = new(directory:, record_id:)
          return instance unless block_given?

          begin
            yield instance
          ensure
            instance.cleanup
          end
        end

        def initialize(directory:, record_id:)
          @directory = directory
          @path = File.join(directory, "holdout.record.json")
          @record_id = record_id
        end

        # OS-boundary posture: the partition is 0o700 and the record 0o600.
        def secure?
          directory_mode = File.stat(@directory).mode & 0o777
          file_mode = File.stat(@path).mode & 0o777
          directory_mode == DIRECTORY_MODE && file_mode == FILE_MODE
        end

        # The holdout partition is outside the runner root.
        def outside?(root)
          !File.realpath(@path).start_with?("#{File.realpath(root)}#{File::SEPARATOR}")
        end

        def cleanup
          FileUtils.remove_entry(@directory) if File.directory?(@directory)
        end
      end
    end
  end
end
