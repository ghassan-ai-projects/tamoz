# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tmpdir"

module Tamoz
  module Evals
    module Harness
      class HeuristicCorpus
        DIRECTORY_MODE = 0o700
        FILE_MODE = 0o600

        attr_reader :train_root, :protected_root, :holdout_root, :evaluator_root

        def self.create(inputs:, &block)
          directory = Dir.mktmpdir("tamoz-heuristic-corpus")
          instance = new(directory:, inputs:).build
          return instance unless block

          begin
            block.call(instance)
          ensure
            instance.cleanup
          end
        end

        def initialize(directory:, inputs:)
          unless inputs.is_a?(Hash) && %i[train development holdout].all? { |key| inputs.key?(key) }
            raise ExecutionError, "heuristic corpus inputs are incomplete"
          end

          @directory = directory
          @train_trajectories = DeepFreeze.call(inputs.fetch(:train))
          @development_tasks = DeepFreeze.call(inputs.fetch(:development))
          @holdout_tasks = DeepFreeze.call(inputs.fetch(:holdout))
          @train_root = File.join(directory, "train")
          @protected_root = File.join(directory, "protected")
          @holdout_root = File.join(@protected_root, "holdout")
          @evaluator_root = File.join(@protected_root, "evaluator")
        end

        def build
          FileUtils.mkdir_p(File.join(@train_root, "trajectories"))
          FileUtils.mkdir_p(@holdout_root)
          FileUtils.mkdir_p(@evaluator_root)
          File.chmod(DIRECTORY_MODE, @protected_root)
          File.chmod(DIRECTORY_MODE, @holdout_root)
          File.chmod(DIRECTORY_MODE, @evaluator_root)
          write_train_trajectories
          write_holdout_partition
          self
        end

        def secure?
          [@protected_root, @holdout_root, @evaluator_root].all? do |path|
            (File.stat(path).mode & 0o777) == DIRECTORY_MODE
          end
        end

        def outside_grant?
          real_train = "#{File.realpath(@train_root)}#{File::SEPARATOR}"
          [@holdout_root, @evaluator_root].none? do |path|
            File.realpath(path).start_with?(real_train)
          end
        end

        def train_trajectory_paths
          Dir.children(File.join(@train_root, "trajectories")).sort.map do |name|
            File.join("trajectories", name)
          end
        end

        def train_ids = @train_trajectories.map { |entry| entry.fetch("trajectory_id") }
        def holdout_ids = @holdout_tasks.map { |entry| entry.fetch("task_id") }
        def train_digest = digest_of(@train_trajectories)
        def holdout_digest = digest_of(@holdout_tasks)
        def development_tasks = @development_tasks
        def holdout_tasks = @holdout_tasks

        def write_evaluator_output(name, content)
          path = File.join(@evaluator_root, name)
          write_corpus_file(path, content)
          path
        end

        def evaluator_report_resolver
          root = @evaluator_root
          lambda do |seal|
            Dir.children(root).sort.each do |name|
              report = JSON.parse(File.read(File.join(root, name), encoding: Encoding::UTF_8))
              return report if report.is_a?(Hash) && report["seal"] == seal
            end
            nil
          end
        end

        def cleanup
          FileUtils.remove_entry(@directory) if File.directory?(@directory)
        end

        private

        def digest_of(value)
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(value))}"
        end

        def write_corpus_file(path, value)
          File.write(path, "#{CanonicalJSON.dump(value)}\n", encoding: Encoding::UTF_8)
          File.chmod(FILE_MODE, path)
        end

        def write_train_trajectories
          @train_trajectories.each do |trajectory|
            write_corpus_file(
              File.join(@train_root, "trajectories", "#{trajectory.fetch("trajectory_id")}.json"),
              trajectory
            )
          end
        end

        def write_holdout_partition
          @holdout_tasks.each do |task|
            write_corpus_file(File.join(@holdout_root, "#{task.fetch("task_id")}.json"), task)
          end
        end
      end
    end
  end
end
