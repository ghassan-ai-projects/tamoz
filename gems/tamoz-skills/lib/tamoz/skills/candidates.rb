# frozen_string_literal: true

module Tamoz
  module Skills
    # A drafted or optimized skill is a candidate: staged outside every skills root, pinned by its tree digest, and
    # installed only on a named approver other than its recorded creator (ADR-034). The manifest is a plain operator
    # file and the approver is free text: the digest pin is the gate, the names are a record.
    # :reek:TooManyStatements :reek:UtilityFunction -- install is one ordered, all-or-nothing procedure.
    module Candidates
      MANIFEST_SUFFIX = ".candidate.json"
      PROMOTIONS = ".promotions.jsonl"
      RETIRED = ".retired"

      module_function

      def stage(directory, created_by:, source:)
        record = compile_one(directory)
        require_bar!(record)
        manifest = { "name" => record.name, "tree_digest" => record.tree_digest, "description" => record.description,
                     "created_by" => String(created_by), "source" => String(source) }
        File.write(manifest_path(directory), JSON.pretty_generate(manifest))
        manifest
      end

      def install(directory, skills_root:, approver:)
        manifest = JSON.parse(File.read(manifest_path(directory)))
        approver = String(approver).strip
        raise Error, "the approving person must be named" if approver.empty?
        raise Error, "#{approver} created this candidate and cannot approve it" if approver == manifest["created_by"]

        record = compile_one(directory)
        raise Error, "the candidate changed after it was staged" unless record.tree_digest == manifest["tree_digest"]

        require_bar!(record)
        root = File.realpath(skills_root)
        retired = replace(record, root)
        entry = manifest.merge("approver" => approver, "installed_at" => Time.now.utc.iso8601, "retired" => retired)
        File.open(File.join(root, PROMOTIONS), "a") { |file| file.puts(JSON.generate(entry)) }
        entry
      end

      # Copy exactly the digested files beside the target and digest the copy again, move the old tree aside, then
      # rename: what is installed is what was approved, and the skill is never half-installed.
      def replace(record, root)
        name = record.name
        target = File.join(root, name)
        holder = File.join(root, ".incoming-#{name}")
        incoming = File.join(holder, name)
        FileUtils.rm_rf(holder)
        record.resource_index.each_key do |path|
          FileUtils.mkdir_p(File.dirname(File.join(incoming, path)))
          FileUtils.cp(File.join(record.directory, path), File.join(incoming, path), preserve: true)
        end
        unless compile_one(incoming).tree_digest == record.tree_digest
          FileUtils.rm_rf(holder)
          raise Error, "the copy of #{name} does not match the approved digest"
        end
        retired = nil
        if File.exist?(target)
          retired = "#{RETIRED}/#{name}-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}"
          FileUtils.mkdir_p(File.join(root, RETIRED))
          File.rename(target, File.join(root, retired))
        end
        File.rename(incoming, target)
        FileUtils.rm_rf(holder)
        retired
      end

      def require_bar!(record)
        issues = Skills.lint(record)
        raise Error, "#{record.name} is below the authoring bar: #{issues.join('; ')}" unless issues.empty?
      end

      def compile_one(directory)
        path = File.expand_path(directory)
        name = File.basename(path)
        snapshot = Skills.compile(sources: [SkillSource.new(id: "candidate", root: File.dirname(path), trust: "workspace")])
        record = snapshot.records["candidate/#{name}"]
        return record if record

        rejection = snapshot.rejections.find { |entry| entry.entry == name }
        raise Error, rejection ? "#{rejection.code}: #{rejection.detail}" : "no skill directory at #{name}"
      end

      def manifest_path(directory) = "#{File.expand_path(directory)}#{MANIFEST_SUFFIX}"

      SCAFFOLD = <<~MARKDOWN
        ---
        name: %<name>s
        description: One sentence on what this skill does. Use when the task needs exactly that.
        metadata:
          tamoz.risk: guarded
        ---

        # %<name>s

        ## When to use it

        Say which tasks this skill is for, and which look similar but are not.

        ## Procedure

        1. The first step, with the evidence it needs.
        2. The step that produces the result.
        3. How to verify the result before finishing.

        ## Rules

        - What must never happen while following this skill.
      MARKDOWN

      # A new skill's starting point, written where its author asks; it meets the authoring bar as written.
      def scaffold(name, parent)
        raise Error, "#{name.inspect} is not a skill name" unless NAME_PATTERN.match?(String(name))

        directory = File.join(File.expand_path(parent), name)
        raise Error, "#{directory} already exists" if File.exist?(directory)

        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, MANIFEST_BASENAME), format(SCAFFOLD, name:))
        directory
      end
    end
  end
end
