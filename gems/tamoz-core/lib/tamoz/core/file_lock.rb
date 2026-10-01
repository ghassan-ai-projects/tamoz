# frozen_string_literal: true

module Tamoz
  module Core
    # Serializes every process that names the same lock file. The lock dies with the descriptor,
    # so a killed holder never wedges it.
    module FileLock
      module_function

      def exclusive(path, mode: 0o600)
        File.open(path, File::RDWR | File::CREAT, mode) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end
    end
  end
end
