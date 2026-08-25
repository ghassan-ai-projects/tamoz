# frozen_string_literal: true

require 'pathname'

module Tamoz
  module Tools
    # Resolves workspace-relative paths and enforces the filesystem boundary.
    # The resolver owns lexical containment, realpath containment, symlink policy,
    # and create-parent checks; tool-specific operations stay in Toolbox.
    # :reek:FeatureEnvy -- filesystem policy is intentionally expressed against
    # the candidate Pathname values, not against this resolver's state.
    # :reek:DataClump -- raw_path/type are the resolver's explicit boundary contract;
    # each operation needs both to preserve the caller's requested path semantics.
    # :reek:TooManyStatements -- the ordered checks are the security contract and
    # must remain visible as separate refusal points.
    # :reek:NilCheck -- :any deliberately has no file/directory predicate.
    # :reek:MissingSafeMethod -- bang methods enforce boundary contracts and have
    # no useful non-raising twin.
    class PathResolver
      MAX_PATH_BYTES = 4096

      def initialize(root)
        @root = root
        @workspace_prefix = "#{root}#{File::SEPARATOR}".freeze
        freeze
      end

      def resolve(raw_path, type:)
        resolve_path(raw_path, type:) { true }
      end

      def resolve_without_symlinks(raw_path, type:)
        resolve_path(raw_path, type:) { |lexical, path| lexical.to_s == path.to_s }
      end

      def validate_path_argument!(raw_path)
        raise ToolArgumentError, 'path must be a string' unless raw_path.is_a?(String)

        raise ToolPolicyError, 'path contains a null byte' if raw_path.include?("\0")
        raise ToolArgumentError, "path exceeds #{MAX_PATH_BYTES} bytes" if raw_path.bytesize > MAX_PATH_BYTES

        reject_absolute!(raw_path)
      end

      def validate_create_path!(raw_path)
        lexical = create_candidate(raw_path)
        raise ToolArgumentError, 'file already exists' if File.exist?(lexical)

        parent = lexical.dirname
        validate_parent!(parent)
        lexical
      rescue SystemCallError
        raise ToolError, 'path is unavailable'
      end

      private

      attr_reader :root, :workspace_prefix

      def resolve_path(raw_path, type:)
        lexical = lexical_path(raw_path)
        path = lexical.realpath
        reject_realpath_escape!(path)
        raise ToolPolicyError, 'patch path must not contain symlinks' unless yield(lexical, path)

        validate_type!(path, type)
        path
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ToolArgumentError, 'path does not exist'
      rescue SystemCallError
        raise ToolError, 'path is unavailable'
      end

      def lexical_path(raw_path)
        text = String(raw_path)
        reject_absolute!(text)
        workspace_path(text)
      end

      def create_candidate(raw_path)
        text = String(raw_path)
        reject_file_path_shape!(text)
        lexical = workspace_path(text)
        raise ToolArgumentError, 'path must name a file' if lexical == root

        lexical
      end

      def workspace_path(text)
        lexical = root.join(text).cleanpath
        reject_lexical_escape!(lexical)
        lexical
      end

      def reject_absolute!(text)
        return unless Pathname.new(text).absolute?

        raise ToolPolicyError, 'path must be relative to the workspace root'
      end

      def reject_lexical_escape!(path)
        return if path == root || path.to_s.start_with?(workspace_prefix)

        raise ToolPolicyError, 'path escapes the workspace root'
      end

      def reject_realpath_escape!(path)
        return if path == root || path.to_s.start_with?(workspace_prefix)

        raise ToolPolicyError, 'path escapes the workspace root'
      end

      def validate_type!(path, type)
        predicate = { file: :file?, directory: :directory? }[type]
        return if predicate.nil? || path.public_send(predicate)

        raise ToolArgumentError, "path is not a #{type}"
      end

      def reject_file_path_shape!(text)
        return unless text.empty? || text == '.' || text.end_with?('/')

        raise ToolArgumentError, 'path must name a file'
      end

      def validate_parent!(parent)
        raise ToolArgumentError, 'parent directory does not exist' unless parent.exist?
        raise ToolArgumentError, 'parent is not a directory' unless parent.directory?
        return if parent.realpath.to_s == parent.to_s

        raise ToolPolicyError, 'parent path must not contain symlinks'
      end
    end
  end
end
