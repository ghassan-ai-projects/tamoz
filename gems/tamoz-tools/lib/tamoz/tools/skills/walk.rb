# frozen_string_literal: true

module Tamoz
  module Tools
    module Skills
      # =========================================================================
      # Canonical tree walk
      # =========================================================================
      #
      # `Dir.children` + `File.lstat` only. `Find.find` is deliberately not used: it
      # follows directory symlinks and gives no lstat guarantee.
      # :reek:MissingSafeMethod — every validator here raises `Rejected`; a
      # predicate twin would invite walking a tree without acting on what it
      # found, which is the failure this class exists to prevent.
      # :reek:TooManyInstanceVariables — the walk carries its accumulators
      # (entries, byte total, case index, seen names) alongside its inputs
      # (directory, label, limits). They are one traversal's state.
      # :reek:TooManyStatements — `visit` is the per-entry gauntlet in order
      # (name, case, type, layout, budget, record) and each step is a refusal the
      # next one depends on; `charge_budget!` and `read_nofollow` are likewise
      # single checks with their own failure messages.
      # :reek:UtilityFunction — `area_of` is a pure classification of a path.
      # :reek:ControlParameter — `reject!`'s optional `entry` names the offending
      # path when there is one; a tree-wide refusal has none.
      # :reek:DataClump — (absolute, path, joined, stat, depth) is ONE directory
      # entry's identity moving through the gauntlet. The lstat result must
      # travel with the path it came from: re-stat'ing later is precisely the
      # TOCTOU this walk exists to avoid.
      # :reek:FeatureEnvy — the validators read the path and the handle they are
      # given; the filesystem's answer is the subject.
      # :reek:LongParameterList — `visit` and `record_entry` carry one entry's
      # identity through the gauntlet: where it is (absolute), what it is called
      # (relative/joined), what the kernel says about it (stat), and how deep the
      # recursion is. Bundling them into a carrier would name the tuple without
      # shortening it, and the lstat result must travel with the path it came
      # from — re-stat'ing later is exactly the TOCTOU this walk avoids.
      class Walk
        ENTRY_TYPES = %w[directory file].freeze

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

        def descend(absolute, relative, depth)
          max_depth = @limits.fetch(:max_depth)
          reject!('skill_depth_exceeded', "depth exceeds #{max_depth}") if depth > max_depth

          Dir.children(absolute).sort.each { |child| visit(absolute, relative, child, depth) }
        rescue SystemCallError
          reject!('skill_realpath_changed', 'tree changed during the walk')
        end

        # One directory entry: name, type, layout, budget, then recurse or record.
        #
        # Type classification precedes layout on purpose: a symlink named
        # `references/` must be reported as the type violation it is, not as a
        # layout surprise. Everything that is not a plain directory or regular
        # file is refused here, before any open.
        def visit(absolute, relative, child, depth)
          path = relative + [child]
          joined = path.join('/')
          validate_component!(child, joined)
          validate_case!(joined)
          entry_absolute = File.join(absolute, child)
          stat = File.lstat(entry_absolute)
          ftype = stat.ftype
          reject!('skill_entry_type_invalid', "#{joined} is a #{ftype}", joined) unless ENTRY_TYPES.include?(ftype)

          validate_layout!(path, stat, joined)
          count_entry!(joined)
          record_entry(entry_absolute, path, joined, stat, depth)
        end

        def record_entry(absolute, path, joined, stat, depth)
          if stat.directory?
            @entries << { path: joined, kind: 'dir', digest: nil, executable: false, area: area_of(path) }
            descend(absolute, path, depth + 1)
          else
            @entries << file_entry(absolute, path, joined, stat)
          end
        end

        def file_entry(absolute, path, joined, stat)
          charge_budget!(joined, stat)
          size = stat.size
          content = read_nofollow(absolute, joined)
          reject!('skill_realpath_changed', "#{joined} changed during the walk", joined) unless content.bytesize == size

          {
            path: joined,
            kind: 'file',
            digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
            executable: stat.mode.anybits?(0o111),
            bytes: size,
            area: area_of(path)
          }
        end

        # A hard link is the one way an inside name can be an outside inode, and
        # there is no portable "is the other name inside my tree?" query — so a
        # file with more than one link is refused rather than followed.
        def charge_budget!(joined, stat)
          size = stat.size
          links = stat.nlink
          reject!('skill_hardlink_rejected', "#{joined} has #{links} links", joined) unless links == 1
          if size > @limits.fetch(:max_resource_bytes)
            reject!('skill_resource_bytes_exceeded', "#{joined} is #{size} bytes", joined)
          end

          max_tree = @limits.fetch(:max_tree_bytes)
          @bytes += size
          return unless @bytes > max_tree

          reject!('skill_tree_bytes_exceeded', "tree exceeds #{max_tree} bytes")
        end

        def read_nofollow(absolute, joined)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(absolute, flags) do |handle|
            handle.binmode
            handle.read.to_s
          end
        rescue SystemCallError
          reject!('skill_entry_type_invalid', "#{joined} could not be read as a regular file", joined)
        end

        def validate_component!(child, joined)
          text = child.dup.force_encoding(Encoding::UTF_8)
          return if text.valid_encoding? && COMPONENT_PATTERN.match?(text)

          reject!('skill_path_invalid', "#{Skills.describe(child)} is not a valid component", joined)
        end

        # ASCII-only components make NFC a no-op; it runs anyway so the property
        # holds if the component alphabet is ever widened, and it is locale
        # independent either way.
        def validate_case!(joined)
          key = joined.unicode_normalize(:nfc).downcase
          reject!('skill_case_collision', "#{joined} collides with #{@seen.fetch(key)}", joined) if @seen.key?(key)

          @seen[key] = joined
        end

        def validate_layout!(path, stat, joined)
          return if path.length > 1

          head = path.first
          if stat.directory?
            return if AREA_DIRECTORIES.include?(head)

            reject!('skill_layout_invalid', "#{joined} is not an allowed skill directory", joined)
          elsif head != MANIFEST_BASENAME
            reject!('skill_layout_invalid', "#{joined} is not allowed beside SKILL.md", joined)
          end
        end

        def count_entry!(joined)
          max_entries = @limits.fetch(:max_tree_entries)
          @count += 1
          return unless @count > max_entries

          reject!('skill_entries_exceeded', "tree exceeds #{max_entries} entries", joined)
        end

        def area_of(path)
          return 'root' if path.length == 1

          head = path.first
          AREA_DIRECTORIES.include?(head) ? head : 'root'
        end

        def reject!(code, detail, entry = nil)
          raise Rejected.new(code, entry || @label, detail)
        end
      end
    end
  end
end
