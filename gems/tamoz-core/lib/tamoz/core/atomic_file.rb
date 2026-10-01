# frozen_string_literal: true

require 'tempfile'

module Tamoz
  module Core
    # Writes a file so a reader sees the old bytes or the new ones, never a torn file: a temp file in the target's
    # directory is written and fsync'd, then renamed over the target (`replace`) or hard-linked to a name that must
    # not exist (`create`), and the directory is fsync'd so the new name survives a crash. It raises the
    # SystemCallError it meets; callers name the failure in their own terms.
    #
    #   Tamoz::Core::AtomicFile.replace('notes.txt', "new\n", mode: 0o644)
    module AtomicFile
      module_function

      # The temp name keeps Tempfile's `<prefix>YYYYMMDD-pid-rand.tmp` shape, which a staging reaper can recognize.
      def replace(path, bytes, mode: nil, prefix: '.tamoz-')
        directory = File.dirname(path.to_s)
        temporary = staged(directory, bytes, mode:, prefix:)
        File.rename(temporary.path, path.to_s)
        fsync_directory(directory)
      ensure
        temporary.close! if temporary && !(temporary.closed? && !File.exist?(temporary.path))
      end

      # Raises Errno::EEXIST when the name exists. `before_publish` runs after the bytes are durable and before the
      # name appears, so a caller can recheck the parent at the last moment.
      def create(path, bytes, mode:, prefix: '.tamoz-create-', before_publish: nil)
        directory = File.dirname(path.to_s)
        temporary = staged(directory, bytes, mode:, prefix:)
        before_publish&.call
        File.link(temporary.path, path.to_s)
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

      def staged(directory, bytes, mode:, prefix:)
        temporary = Tempfile.new([prefix, '.tmp'], directory, binmode: true)
        write_durably(temporary, bytes, mode)
        temporary
      rescue StandardError
        discard(temporary)
        raise
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
