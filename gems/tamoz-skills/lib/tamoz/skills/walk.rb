# frozen_string_literal: true

module Tamoz
  module Skills
    # Walks one skill directory with `lstat` and no-follow reads only (`Find.find` would follow directory links),
    # refusing anything but plain files and directories before it opens them.
    class Walk
      ENTRY_TYPES = %w[directory file].freeze

      # One entry as lstat saw it when the walk reached it; re-stat'ing later would reopen the race the walk closes.
      Node = Data.define(:absolute, :segments, :stat) do
        def path = segments.join('/')
        def area = segments.length > 1 && AREA_DIRECTORIES.include?(segments.first) ? segments.first : 'root'
      end

      def initialize(directory, label, limits)
        @directory = directory
        @label = label
        @limits = limits
        @entries = []
        @bytes = 0
        @count = 0
        @seen = {}
      end

      def call
        descend(@directory, [], 0)
        @entries.sort_by { |entry| entry.fetch(:path) }.freeze
      end

      private

      def descend(absolute, segments, depth)
        limit = @limits.fetch(:max_depth)
        reject!('skill_depth_exceeded', "depth exceeds #{limit}") if depth > limit

        Skills.visible_children(absolute).each { |child| visit(absolute, segments + [child], depth) }
      rescue SystemCallError
        reject!('skill_realpath_changed', 'tree changed during the walk')
      end

      def visit(parent, segments, depth)
        check_name!(segments)
        absolute = File.join(parent, segments.last)
        node = Node.new(absolute:, segments:, stat: File.lstat(absolute))
        check_type!(node)
        count!
        node.stat.directory? ? enter(node, depth) : @entries << file_entry(node)
      end

      def enter(node, depth)
        @entries << { path: node.path, kind: 'dir', digest: nil, executable: false, area: node.area }
        descend(node.absolute, node.segments, depth + 1)
      end

      def file_entry(node)
        stat = node.stat
        charge!(node)
        content = read(node)
        reject!('skill_realpath_changed', "#{node.path} changed during the walk") unless content.bytesize == stat.size

        { path: node.path, kind: 'file', digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
          executable: stat.mode.anybits?(0o111), bytes: stat.size, area: node.area }
      end

      def check_name!(segments)
        path = segments.join('/')
        child = segments.last.dup.force_encoding(Encoding::UTF_8)
        unless child.valid_encoding? && COMPONENT_PATTERN.match?(child)
          reject!('skill_path_invalid', "#{Skills.describe(path)} is not a valid path component")
        end

        key = path.unicode_normalize(:nfc).downcase
        reject!('skill_case_collision', "#{path} collides with #{@seen.fetch(key)}") if @seen.key?(key)
        @seen[key] = path
      end

      def check_type!(node)
        type = node.stat.ftype
        reject!('skill_entry_type_invalid', "#{node.path} is a #{type}") unless ENTRY_TYPES.include?(type)
      end

      def count!
        limit = @limits.fetch(:max_tree_entries)
        reject!('skill_entries_exceeded', "tree exceeds #{limit} entries") if (@count += 1) > limit
      end

      # A hard link is the one way an inside name can be an outside inode, so a multiply-linked file is refused.
      def charge!(node)
        stat = node.stat
        size = stat.size
        reject!('skill_hardlink_rejected', "#{node.path} has #{stat.nlink} links") unless stat.nlink == 1
        if size > @limits.fetch(:max_resource_bytes)
          reject!('skill_resource_bytes_exceeded',
                  "#{node.path} is #{size} bytes")
        end

        limit = @limits.fetch(:max_tree_bytes)
        reject!('skill_tree_bytes_exceeded', "tree exceeds #{limit} bytes") if (@bytes += size) > limit
      end

      def read(node)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(node.absolute, flags) { |handle| handle.binmode.read.to_s }
      rescue SystemCallError
        reject!('skill_entry_type_invalid', "#{node.path} could not be read as a regular file")
      end

      def reject!(code, detail) = raise(Rejected.new(code, @label, detail))
    end
  end
end
