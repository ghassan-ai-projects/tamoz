# frozen_string_literal: true

module Tamoz
  module Approval
    # The one spelling of a request target that policy globs are matched against.
    module TargetPath
      module_function

      def canonical(target, workspace_root)
        target = target.to_s
        return target if target.include?('://')

        # A symlink whose target is gone resolves nowhere: canonicalize the
        # literal path so glob denies still match it, rather than crashing.
        return File.expand_path(target, workspace_root) if File.symlink?(target) && !File.exist?(target)
        return File.realpath(target, workspace_root) if File.exist?(target)

        File.expand_path(target, workspace_root)
      end
    end

    private_constant :TargetPath
  end
end
