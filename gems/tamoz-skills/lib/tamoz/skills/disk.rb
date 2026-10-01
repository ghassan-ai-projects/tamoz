# frozen_string_literal: true

module Tamoz
  module Skills
    # Every filesystem question the compiler asks outside a skill's tree walk. It only reads; a wrong answer is a
    # typed rejection naming the source ('.') or the skill.
    module Disk
      module_function

      def source_root(source)
        root = File.realpath(source.root)
        return root if File.directory?(root) && !File.lstat(root).symlink?

        raise Rejected.new('skill_source_not_directory', '.', 'source root is not a directory')
      rescue SystemCallError
        raise Rejected.new('skill_source_unavailable', '.', 'source root is unavailable')
      end

      def skill_names(root, limit)
        names = Skills.visible_children(root)
        return names if names.length <= limit

        raise Rejected.new('skill_source_limit', '.', "source holds more than #{limit} entries")
      end

      def skill_directory(root, child)
        reject!('skill_name_invalid', Skills.describe(child), 'invalid directory name') unless component?(child)

        directory = File.join(root, child)
        type = File.lstat(directory).ftype
        reject!('skill_entry_type_invalid', child, "#{type} is not a skill directory") unless type == 'directory'
        reject!('skill_name_invalid', child, 'directory name is not a skill name') unless NAME_PATTERN.match?(child)
        unmoved!(directory, child)
      end

      # Checked before and after reading, so a directory swapped mid-compile is a rejection, not a skill.
      def unmoved!(directory, child)
        return directory if File.realpath(directory) == directory

        raise Rejected.new('skill_realpath_changed', child, 'skill directory resolves elsewhere')
      end

      def manifest_text(directory, child, limit)
        path = File.join(directory, MANIFEST_BASENAME)
        size = File.lstat(path).size
        reject!('skill_manifest_bytes_exceeded', child, "SKILL.md is #{size} bytes, limit #{limit}") if size > limit

        text = File.binread(path).force_encoding(Encoding::UTF_8)
        return text if text.valid_encoding? && !text.include?("\0")

        raise Rejected.new('skill_manifest_not_utf8', child, 'SKILL.md is not UTF-8 text')
      rescue SystemCallError
        raise Rejected.new('skill_manifest_missing', child, 'SKILL.md is unavailable')
      end

      def component?(value)
        value.is_a?(String) && value.dup.force_encoding(Encoding::UTF_8).valid_encoding? &&
          COMPONENT_PATTERN.match?(value)
      end

      def reject!(code, entry, detail) = raise(Rejected.new(code, entry, detail))
    end
  end
end
