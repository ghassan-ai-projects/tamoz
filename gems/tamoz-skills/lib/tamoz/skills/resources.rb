# frozen_string_literal: true

module Tamoz
  module Skills
    # Reads one indexed resource of a compiled skill. The only name a caller can give is an exact index key; the
    # bytes read must hash to the digest pinned at compile time, which is what makes a swap of an intermediate
    # directory useless (NOFOLLOW guards only the last component).
    module Resources
      module_function

      # Validates without reading, so an unknown, unreadable or oversized resource surfaces at plan review.
      def entry!(record, path, limits)
        entry = record.resource_index[path]
        argument!("skill_resource_unknown: #{Skills.describe(path)} is not indexed") unless entry
        unless entry.readable?
          argument!("skill_resource_not_readable: #{entry.path} is in #{entry.area}/ and is indexed for identity only")
        end
        limit = limits.fetch(:max_read_bytes)
        if entry.bytes > limit
          argument!("skill_resource_too_large: #{entry.path} is #{entry.bytes} bytes, limit #{limit}")
        end
        entry
      end

      def read(record, path, limits)
        entry = entry!(record, path, limits)
        content = verified_bytes(File.join(record.directory, entry.path), entry)
        policy!("skill_resource_not_text: #{entry.path} is not UTF-8 text") unless
          content.valid_encoding? && !content.include?("\0")
        content
      end

      def verified_bytes(absolute, entry)
        unless defined?(File::NOFOLLOW)
          policy!('skill_resource_changed: this platform cannot open without following links')
        end
        unmoved!(absolute, entry)
        content = File.open(absolute, File::RDONLY | File::NOFOLLOW) { |handle| indexed_bytes(handle, entry) }
        policy!("skill_resource_changed: #{entry.path} digest does not match its index") unless matches?(content, entry)
        unmoved!(absolute, entry)
        content.force_encoding(Encoding::UTF_8)
      rescue Errno::ELOOP, Errno::EMLINK
        policy!("skill_resource_changed: #{entry.path} became a link")
      rescue SystemCallError
        policy!("skill_resource_changed: #{entry.path} is unavailable")
      end

      def indexed_bytes(handle, entry)
        stat = handle.stat
        unless stat.file? && stat.nlink == 1 && stat.size == entry.bytes
          policy!("skill_resource_changed: #{entry.path} no longer matches its index")
        end
        handle.binmode.read(entry.bytes + 1).to_s
      end

      def matches?(content, entry)
        content.bytesize == entry.bytes && "sha256:#{Digest::SHA256.hexdigest(content)}" == entry.digest
      end

      # Checked before and after the read, narrowing the intermediate-component window from both sides.
      def unmoved!(absolute, entry)
        policy!("skill_resource_changed: #{entry.path} resolves outside its skill tree") unless
          File.realpath(absolute) == absolute
      end

      def argument!(message) = raise(Tamoz::Core::ToolArgumentError, message)
      def policy!(message) = raise(Tamoz::Core::ToolPolicyError, message)
    end
  end
end
