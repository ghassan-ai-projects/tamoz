# frozen_string_literal: true

module Tamoz
  module Core
    # Serializes every process that names the same lock file; a killed holder never wedges it.
    module FileLock
      module_function

      def exclusive(path)
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end
    end
  end
end
