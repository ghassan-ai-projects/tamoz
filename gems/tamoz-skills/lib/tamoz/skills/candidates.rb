# frozen_string_literal: true

module Tamoz
  module Skills
    # The rules for a drafted or optimized skill: when it may be staged, and when a staged copy may be installed.
    # Pure: it reads and compiles, and leaves every write to its caller (ADR-034: generated skills never approve
    # themselves; the manifest is an operator file, so the digest pin is the gate and the names are a record).
    module Candidates
      MANIFEST_SUFFIX = '.candidate.json'
      TEMPLATE = File.read(File.expand_path('../../../data/skill-template.md', __dir__)).freeze

      module_function

      # The manifest to write beside a draft that meets the authoring bar.
      def manifest(directory, created_by:, source:)
        record = compile(directory)
        require_bar!(record)
        { 'name' => record.name, 'tree_digest' => record.tree_digest, 'description' => record.description,
          'created_by' => String(created_by), 'source' => String(source) }
      end

      # The record to install, when this approver may install this staged draft exactly as staged.
      def approve(directory, manifest:, approver:)
        approver = String(approver).strip
        raise Error, 'the approving person must be named' if approver.empty?
        raise Error, "#{approver} created this candidate and cannot approve it" if approver == manifest['created_by']

        record = compile(directory)
        raise Error, 'the candidate changed after it was staged' unless record.tree_digest == manifest['tree_digest']

        require_bar!(record)
        record
      end

      def scaffold(name)
        raise Error, "#{name.inspect} is not a skill name" unless NAME_PATTERN.match?(String(name))

        format(TEMPLATE, name:)
      end

      def compile(directory)
        path = File.expand_path(directory)
        name = File.basename(path)
        snapshot = Skills.compile(sources: [SkillSource.new(id: 'candidate', root: File.dirname(path),
                                                            trust: 'workspace')])
        record = snapshot.records["candidate/#{name}"]
        return record if record

        rejection = snapshot.rejections.find { |entry| entry.entry == name }
        raise Error, rejection ? "#{rejection.code}: #{rejection.detail}" : "no skill directory at #{name}"
      end

      def require_bar!(record)
        issues = Skills.lint(record)
        raise Error, "#{record.name} is below the authoring bar: #{issues.join('; ')}" unless issues.empty?
      end

      def manifest_path(directory) = "#{File.expand_path(directory)}#{MANIFEST_SUFFIX}"
    end
  end
end
