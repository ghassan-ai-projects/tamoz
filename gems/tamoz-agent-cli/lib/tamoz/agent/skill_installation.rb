# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module Tamoz
  module Agent
    # The operator's writes for skill authoring; every rule they follow is `Tamoz::Skills`'s.
    class SkillInstallation
      PROMOTIONS = '.promotions.jsonl'
      RETIRED = '.retired'

      def self.scaffold(name, parent)
        directory = File.join(File.expand_path(parent), name)
        raise Tamoz::Skills::Error, "#{directory} already exists" if File.exist?(directory)

        text = Tamoz::Skills.scaffold(name)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, Tamoz::Skills::MANIFEST_BASENAME), text)
        directory
      end

      def self.stage(directory, created_by:, source:)
        manifest = Tamoz::Skills.candidate_manifest(directory, created_by:, source:)
        File.write(Tamoz::Skills.manifest_path(directory), JSON.pretty_generate(manifest))
        manifest
      end

      # A private workspace for one drafting turn: the exported trajectory, and the draft's directory made ready
      # because create_file never makes parents.
      def self.draft_workspace(session_dir, label, name, trajectory)
        workspace = File.join(session_dir, 'skill-drafts', label)
        Tamoz::Core::PrivateDirectory.secure(File.join(workspace, name, 'references'))
        File.write(File.join(workspace, 'trajectory.md'), trajectory)
        workspace
      end

      # Stages a finished draft, dropping the references/ directory it was given if it stayed empty.
      def self.stage_draft(directory, created_by:, source:)
        references = File.join(directory, 'references')
        Dir.rmdir(references) if Dir.exist?(references) && Dir.empty?(references)
        stage(directory, created_by:, source:)
      end

      def initialize(skills_root)
        @root = File.realpath(skills_root)
      end

      # Copies exactly the approved files beside the target, checks the copy against the approved digest, moves the
      # old version aside, then renames: what is installed is what was approved, never half of it.
      def install(directory, approver:)
        manifest = JSON.parse(File.read(Tamoz::Skills.manifest_path(directory)))
        record = Tamoz::Skills.approve_candidate(directory, manifest:, approver:)
        retired = replace(record)
        entry = manifest.merge('approver' => approver.strip, 'installed_at' => Time.now.utc.iso8601,
                               'retired' => retired)
        File.open(File.join(@root, PROMOTIONS), 'a') { |file| file.puts(JSON.generate(entry)) }
        entry
      end

      private

      def replace(record)
        name = record.name
        holder = File.join(@root, ".incoming-#{name}")
        incoming = File.join(holder, name)
        FileUtils.rm_rf(holder)
        copy(record, incoming)
        retired = retire(name)
        File.rename(incoming, File.join(@root, name))
        retired
      ensure
        FileUtils.rm_rf(holder) if holder
      end

      def copy(record, incoming)
        record.resource_index.each_key do |path|
          FileUtils.mkdir_p(File.dirname(File.join(incoming, path)))
          FileUtils.cp(File.join(record.directory, path), File.join(incoming, path), preserve: true)
        end
        return if Tamoz::Skills.candidate_record(incoming).tree_digest == record.tree_digest

        raise Tamoz::Skills::Error, "the copy of #{record.name} does not match the approved digest"
      end

      def retire(name)
        target = File.join(@root, name)
        return nil unless File.exist?(target)

        retired = "#{RETIRED}/#{name}-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}"
        FileUtils.mkdir_p(File.join(@root, RETIRED))
        File.rename(target, File.join(@root, retired))
        retired
      end
    end
  end
end
