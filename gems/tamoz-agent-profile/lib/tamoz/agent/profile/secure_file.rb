# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # Opening and reading an operator-owned file safely (P8-E).
      #
      # The whole point of this class is that every check happens against the
      # OPEN DESCRIPTOR, not against a path that could be re-pointed between the
      # check and the read: the file is opened O_NOFOLLOW so a final symlink is
      # refused by the kernel, and ownership, mode and size are read from fstat
      # on that same descriptor. Validation and reading therefore share one file
      # description, and a swap in between cannot be observed.
      #
      # O_NONBLOCK is there because opening a FIFO read-only blocks until a
      # writer appears; without it a profile path pointing at a named pipe would
      # hang the loader forever instead of failing. The regular-file check on the
      # resulting descriptor then rejects it with a typed error.
      #
      # Used for the profile itself and for both operator-side registries, which
      # is why it is a separate object rather than private to the loader.
      #
      # Pinned by test/agent_profile_test.rb (symlink, permissions, FIFO,
      # oversized, non-UTF-8) and test/agent_profile_adoption_seams_test.rb.
      #
      # :reek:MissingSafeMethod — the bangs are refusals that raise.
      # :reek:BooleanParameter :reek:ControlParameter — `permissions:` is the
      # existing internal API and its value is computed at the call site
      # (`permissions: !suggestion`), so it cannot be split into two methods
      # without pushing the same conditional up. A named policy would be the
      # honest fix; that is an API change, not a move, so it is left for Q4.
      # :reek:TooManyStatements — `open_verified` is one open plus its errno
      # translation table, and `read_bytes` is the size/encoding gauntlet; both
      # are single indivisible operations.
      class SecureFile
        def self.open_verified(path, permissions: true, &)
          new(path).open_verified(permissions:, &)
        end

        def self.verify_permissions!(path)
          new(path).verify_permissions!
        end

        def self.read_bytes(handle, path)
          new(path).read_bytes(handle)
        end

        def initialize(path)
          @path = path
        end

        # Opens without following a final symlink and verifies the permission
        # rules against the open descriptor. Every errno the open can raise is
        # translated into a typed profile error, so no errno detail leaks.
        def open_verified(permissions: true)
          File.open(@path, File::RDONLY | NOFOLLOW | NONBLOCK) do |handle|
            refuse_non_regular_file!(handle.stat)

            verify_handle!(handle) if permissions
            yield handle
          end
        rescue Errno::ELOOP, Errno::EMLINK, Errno::EOPNOTSUPP
          raise PermissionError, "#{@path}: profile must not be a symlink"
        rescue Errno::ENOENT
          raise ValidationError, "#{@path}: profile file does not exist"
        rescue Errno::EISDIR
          raise ValidationError, "#{@path}: profile must be a regular file"
        rescue Errno::EACCES, Errno::EPERM
          raise PermissionError, "#{@path}: profile is not readable"
        end

        def verify_permissions!
          open_verified { nil }
          nil
        end

        # Size is checked twice on purpose: once from fstat, and once on what was
        # actually read. The first refuses an oversized file cheaply; the second
        # is what holds if the file grew between the stat and the read.
        def read_bytes(handle)
          stat = handle.stat
          raise ValidationError, "#{@path}: not a regular file" unless stat.file?

          refuse_oversized!(stat.size)
          bytes = handle.read(MAX_BYTES + 1) || +''
          refuse_oversized!(bytes.bytesize)
          decode(bytes)
        end

        private

        def refuse_oversized!(size)
          return unless size > MAX_BYTES

          raise ValidationError, "#{@path}: profile exceeds #{MAX_BYTES} bytes"
        end

        def decode(bytes)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          return text if text.valid_encoding?

          raise ValidationError, "#{@path}: profile is not valid UTF-8"
        end

        def refuse_non_regular_file!(stat)
          return if stat.file?

          raise PermissionError, "#{@path}: profile must be a regular file"
        end

        def verify_handle!(handle)
          stat = handle.stat
          refuse_non_regular_file!(stat)
          raise PermissionError, "#{@path}: profile must be owned by the effective user" unless stat.owned?
          raise PermissionError, "#{@path}: profile mode must be exactly 0600" unless (stat.mode & 0o777) == 0o600

          verify_parents!
        end

        # Walks up from the file's directory while the directories are still ours,
        # refusing any that group or other could write to. A sticky directory
        # (/tmp) is exempt from the write check, because sticky already prevents
        # one user replacing another's entries.
        #
        # :reek:TooManyStatements — one upward walk with two refusals per level;
        # the loop and its guards are a single traversal.
        def verify_parents!
          directory = File.dirname(@path)
          immediate = true
          loop do
            stat = File.stat(directory)
            refuse_writable_directory!(directory, stat.mode)
            refuse_readable_directory!(directory, stat) if immediate

            parent = File.dirname(directory)
            break if parent == directory || !stat.owned?

            directory = parent
            immediate = false
          end
        end

        def refuse_writable_directory!(directory, mode)
          return if sticky?(mode) || mode.nobits?(0o022)

          raise PermissionError, "#{directory}: profile directory must not be writable by group or other"
        end

        # Only the immediate directory is held to this: a readable ancestor does
        # not disclose the profile, but a readable containing directory does.
        def refuse_readable_directory!(directory, stat)
          mode = stat.mode
          return if sticky?(mode) || mode.nobits?(0o004) || !stat.owned?

          raise PermissionError, "#{directory}: profile directory must not be readable by other"
        end

        # :reek:UtilityFunction — a pure bit test on a mode.
        def sticky?(mode)
          mode.anybits?(0o1000)
        end
      end
    end
  end
end
