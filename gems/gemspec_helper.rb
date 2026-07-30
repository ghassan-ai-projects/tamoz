# frozen_string_literal: true

module TamozGemspec
  REPOSITORY = "https://github.com/ghassan-ai-projects/tamoz"
  ALLOWED_FILES = %w[LICENSE README.md].freeze

  module_function

  def build(name:, version:, summary:, description:, dependencies: [], executable: nil)
    root = File.expand_path(name, __dir__)

    Gem::Specification.new do |spec|
      spec.name = name
      spec.version = version
      spec.authors = ["Ghassan Al-Dakkak"]
      spec.email = ["opensource@ghassan.blog"]
      spec.summary = summary
      spec.description = description
      spec.homepage = REPOSITORY
      spec.license = "MIT"
      spec.required_ruby_version = Gem::Requirement.new(">= 3.3", "< 5.0")
      spec.required_rubygems_version = Gem::Requirement.new(">= 3.5")

      patterns = [
        "lib/**/*.rb",
        "schemas/**/*.json",
        "suites/**/*.json",
        "baselines/**/*.json",
        "exe/*",
        *ALLOWED_FILES
      ]
      spec.files = Dir.chdir(root) do
        patterns.flat_map { |pattern| Dir.glob(pattern) }
                .select { |path| File.file?(path) }
                .sort
      end
      spec.require_paths = ["lib"]

      if executable
        spec.bindir = "exe"
        spec.executables = [executable]
      end

      spec.metadata = {
        "bug_tracker_uri" => "#{REPOSITORY}/issues",
        "changelog_uri" => "#{REPOSITORY}/releases",
        "documentation_uri" => "#{REPOSITORY}/tree/main/docs",
        "rubygems_mfa_required" => "true",
        "source_code_uri" => REPOSITORY
      }

      dependencies.each do |dependency_name, requirement|
        spec.add_runtime_dependency(dependency_name, requirement)
      end
    end
  end
end
