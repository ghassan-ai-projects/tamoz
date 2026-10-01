# frozen_string_literal: true

module Tamoz
  module Skills
    # Where an operator's skills come from: the bundled set, one operator directory, or both. A checkout the agent
    # can write must not be able to write its own instructions, so a skills root and the workspace may not contain
    # one another, whichever way round.
    module Roots
      module_function

      # :reek:BooleanParameter :reek:ControlParameter -- `bundled` is the operator's on/off switch itself.
      def snapshot(root, workspace_root, bundled)
        sources = []
        if bundled
          sources << SkillSource.new(id: 'bundled', root: disjoint!(BUNDLED_ROOT, workspace_root),
                                     trust: 'bundled')
        end
        if root
          sources << SkillSource.new(id: 'operator', root: disjoint!(root, workspace_root), trust: 'operator',
                                     precedence: 1)
        end
        sources.empty? ? Skills.empty : Skills.compile(sources:)
      end

      def disjoint!(root, workspace_root)
        resolved = real_path(root)
        return resolved unless workspace_root

        workspace = real_path(workspace_root)
        return resolved unless within?(resolved, workspace) || within?(workspace, resolved)

        raise Error, "skills root #{resolved} overlaps the workspace #{workspace}; " \
                     'skills are instructions and must live outside the tree being worked on'
      end

      def within?(path, directory) = path == directory || path.start_with?("#{directory}#{File::SEPARATOR}")

      # The deepest existing ancestor is resolved, so a root that does not exist yet compares under the same links
      # as the workspace (/var and /private/var).
      def real_path(path)
        expanded = File.expand_path(path)
        return File.realpath(expanded) if File.exist?(expanded)

        parent = File.dirname(expanded)
        parent == expanded ? expanded : File.join(real_path(parent), File.basename(expanded))
      end
    end
  end
end
