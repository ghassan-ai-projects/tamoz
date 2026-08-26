# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Evals
    module Harness
      module ExternalInputs
        module_function

        def require_manifest_or_root!(manifest, root, label)
          return if manifest || root

          raise ExecutionError, "#{label} requires an explicit external input manifest or root"
        end

        def absolute_root!(root, label)
          value = File.expand_path(String(root))
          unless File.directory?(value) && File.absolute_path(value) == value
            raise ExecutionError, "#{label} root must be an existing absolute directory"
          end

          value.freeze
        rescue TypeError, ArgumentError
          raise ExecutionError, "#{label} root must be an existing absolute directory"
        end

        def document(manifest, descriptor, label:)
          path = path_for(manifest, descriptor, label:)
          bytes = File.binread(path)
          expected = descriptor["sha256"] if descriptor.is_a?(Hash)
          if expected && Digest::SHA256.hexdigest(bytes) != expected
            raise ExecutionError, "#{label} digest does not match its manifest"
          end

          JSON.parse(bytes, create_additions: false)
        rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => error
          raise ExecutionError, "#{label} is invalid: #{error.message}"
        end

        def path_for(manifest, descriptor, label:)
          raise ExecutionError, "#{label} requires an external input manifest" unless manifest

          value = descriptor.is_a?(Hash) ? descriptor.fetch("path") : descriptor
          manifest.path_for(String(value), label:)
        rescue KeyError, TypeError
          raise ExecutionError, "#{label} path is invalid"
        end

        def case_paths(manifest, descriptor, root, label:)
          if root
            return Dir[File.join(absolute_root!(root, label), "*.case.json")].sort.freeze
          end

          value = document(manifest, descriptor, label:)
          entries = if value.is_a?(Hash)
                      value.fetch("case_paths", value.fetch("cases"))
                    else
                      value
                    end
          unless entries.is_a?(Array) && !entries.empty?
            raise ExecutionError, "#{label} must contain explicit case paths"
          end

          entries.map { |entry| path_for(manifest, entry, label:) }.freeze
        rescue KeyError, TypeError
          raise ExecutionError, "#{label} must contain explicit case paths"
        end

        def required_manifest_value(manifest, field, label:)
          raise ExecutionError, "#{label} requires an external input manifest" unless manifest

          value = manifest.public_send(field)
          raise ExecutionError, "#{label} is missing" if value.nil?

          value
        rescue NoMethodError
          raise ExecutionError, "#{label} is missing"
        end
      end
    end
  end
end
