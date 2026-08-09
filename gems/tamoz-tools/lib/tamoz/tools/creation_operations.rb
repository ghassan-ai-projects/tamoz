# frozen_string_literal: true

require 'digest'
require 'tempfile'

module Tamoz
  module Tools
    # Creates new files through the no-overwrite publication boundary.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:TooManyStatements :reek:UncommunicativeVariableName
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    class CreationOperations
      def initialize(toolbox)
        @toolbox = toolbox
        freeze
      end

      def create(arguments)
        prepared = prepare(arguments)
        atomic_create(prepared.fetch(:path), prepared.fetch(:content), prepared.fetch(:mode))
        receipt(arguments.fetch('path'), prepared)
      end

      def preview(path, content, mode, digest)
        header = "--- create: #{path}\nmode: #{mode}\nsize: #{content.bytesize}\nsha256: #{digest}\ncontent:\n"
        remaining = toolbox.__send__(:maximum_effect_output_bytes, 'create_file') - header.bytesize
        if remaining <= 0 || content.bytesize <= remaining
          "#{header}#{content}"
        else
          "#{header}#{content.byteslice(0,
                                        remaining)}"
        end
      end

      private

      attr_reader :toolbox

      def prepare(arguments)
        {
          path: toolbox.__send__(:validate_create_path!, arguments.fetch('path')),
          content: arguments.fetch('content'),
          mode: arguments.fetch('mode', '0644').to_i(8),
          expected: arguments.fetch('expected_sha256')
        }.freeze
      end

      def atomic_create(target_path, content, mode)
        parent = target_path.dirname
        temp = nil
        published = false
        begin
          temp = Tempfile.new(['.tamoz-create-', '.tmp'], parent.to_s, binmode: true)
          temp.write(content.b)
          temp.flush
          temp.fsync
          temp.chmod(mode)
          temp.fsync
          temp.close
          revalidate_parent(parent)
          File.link(temp.path, target_path.to_s)
          published = true
        rescue Errno::EEXIST
          raise ToolArgumentError, 'file already exists'
        rescue SystemCallError => e
          raise ToolError, "atomic create failed: #{e.class}"
        ensure
          begin
            temp&.close!
          rescue SystemCallError
            nil
          end
          toolbox.__send__(:fsync_directory, parent) if published
        end
      end

      def revalidate_parent(parent)
        raise ToolArgumentError, 'parent directory does not exist' unless parent.exist?
        raise ToolArgumentError, 'parent is not a directory' unless parent.directory?
        raise ToolPolicyError, 'parent path must not contain symlinks' unless parent.realpath.to_s == parent.to_s
      end

      def receipt(display_path, prepared)
        path = prepared.fetch(:path)
        content = path.read(encoding: Encoding::UTF_8)
        actual = Digest::SHA256.hexdigest(content)
        raise ToolError, 'created file did not verify' unless actual == prepared.fetch(:expected)

        <<~TEXT.chomp
          Created #{display_path}
          mode: #{format('%04o', path.stat.mode & 0o777)}
          size: #{content.bytesize}
          sha256: #{actual}
        TEXT
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  end
end
