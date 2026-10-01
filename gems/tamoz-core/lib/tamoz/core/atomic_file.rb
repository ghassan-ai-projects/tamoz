# frozen_string_literal: true

require 'tempfile'

module Tamoz
  module Core
    # A file write a reader sees whole or not at all: temp file, fsync, rename or link, fsync the directory.
    module AtomicFile
      # What a plain File.write creates. Read once: File.umask clears and restores the process umask, so reading
      # it per write races with every other thread that creates a file.
      DEFAULT_MODE = 0o666 & ~File.umask

      module_function

      def replace(path, bytes, mode: nil, prefix: '.tamoz-')
        directory = File.dirname(path.to_s)
        temporary = staged(directory, bytes, mode:, prefix:)
        File.rename(temporary.path, path.to_s)
        discard(temporary)
        fsync_directory(directory)
      ensure
        discard(temporary)
      end

      # Raises Errno::EEXIST when the name exists; `before_publish` runs once the bytes are durable.
      def create(path, bytes, mode:, prefix: '.tamoz-create-', before_publish: nil)
        directory = File.dirname(path.to_s)
        temporary = staged(directory, bytes, mode:, prefix:)
        before_publish&.call
        File.link(temporary.path, path.to_s)
        discard(temporary)
        fsync_directory(directory)
      ensure
        discard(temporary)
      end

      # Best effort: a filesystem that cannot fsync a directory still has the file.
      def fsync_directory(directory)
        File.open(directory.to_s, File::RDONLY, &:fsync)
      rescue SystemCallError
        nil
      end

      # `ensure`, not `rescue`: an interrupt or a killed thread mid-write must not leave a temp file behind.
      def staged(directory, bytes, mode:, prefix:)
        temporary = Tempfile.new([prefix, '.tmp'], directory, binmode: true)
        write_durably(temporary, bytes, mode)
        written = temporary
      ensure
        discard(temporary) unless written
      end

      def write_durably(temporary, bytes, mode)
        temporary.write(bytes)
        temporary.flush
        temporary.fsync
        if mode
          temporary.chmod(mode)
          temporary.fsync
        end
        temporary.close
      end

      def discard(temporary)
        temporary&.close!
      rescue SystemCallError
        nil
      end
      private_class_method :staged, :write_durably, :discard
    end
  end
end
