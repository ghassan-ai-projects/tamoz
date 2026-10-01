# frozen_string_literal: true

require 'digest'
require 'json'
require 'psych'
require 'tamoz/core'

require_relative 'skills/version'
require_relative 'skills/constants'
require_relative 'skills/values'
require_relative 'skills/candidates'
require_relative 'skills/catalog'
require_relative 'skills/collisions'
require_relative 'skills/compiler'
require_relative 'skills/disk'
require_relative 'skills/frontmatter_scanner'
require_relative 'skills/frontmatter'
require_relative 'skills/lint'
require_relative 'skills/manifest'
require_relative 'skills/rendering'
require_relative 'skills/resources'
require_relative 'skills/roots'
require_relative 'skills/snapshot'
require_relative 'skills/tree'
require_relative 'skills/walk'

module Tamoz
  # Portable Agent Skills: directories holding a SKILL.md plus optional resources. Three properties are
  # structural: compiling a skill executes nothing; nothing a skill says widens authority (`allowed-tools` and
  # `tamoz.risk` are recorded and shown, never consumed); and a skill's identity is the digest of its whole tree.
  #
  #   snapshot = Tamoz::Skills.operator_snapshot(root: '/opt/skills', workspace_root: Dir.pwd, bundled: true)
  #   Tamoz::Skills::Catalog.new(snapshot).render
  module Skills
    private_constant :Candidates, :Collisions, :Compiler, :Disk, :Frontmatter, :FrontmatterScanner, :Lint, :Manifest,
                     :Rejected, :Rendering, :Resources, :Roots, :Tree, :Walk

    module_function

    def compile(sources:, bindings: {}, limits: LIMITS) = Compiler.new(sources:, bindings:, limits:).compile
    def empty = EMPTY
    def bundled_root = BUNDLED_ROOT

    # :reek:BooleanParameter -- `bundled` is the operator's on/off switch itself.
    def operator_snapshot(root: nil, workspace_root: nil, bundled: false)
      Roots.snapshot(root, workspace_root, bundled)
    end

    def disjoint!(root, workspace_root) = Roots.disjoint!(root, workspace_root)

    def lint(record) = Lint.call(record)

    def scaffold(name) = Candidates.scaffold(name)
    def candidate_manifest(directory, created_by:, source:) = Candidates.manifest(directory, created_by:, source:)
    def approve_candidate(directory, manifest:, approver:) = Candidates.approve(directory, manifest:, approver:)
    def candidate_record(directory) = Candidates.compile(directory)
    def manifest_path(directory) = Candidates.manifest_path(directory)

    def read_resource_entry!(record, path, limits: LIMITS) = Resources.entry!(record, path, limits)
    def read_resource(record, path, limits: LIMITS) = Resources.read(record, path, limits)
    def render_load(record, available_tools:) = Rendering.load(record, available_tools)
    def render_resource(record, path, content) = Rendering.resource(record, path, content)
    def render_catalog(snapshot) = Rendering.catalog(snapshot)

    # Dotfiles (.DS_Store, .git) are neither walked, digested nor readable.
    def visible_children(directory) = Dir.children(directory).reject { |child| child.start_with?('.') }.sort

    # Bounded, control-free and path-free: what an error message may say about caller-supplied text.
    def describe(value) = String(value).byteslice(0, 120).to_s.scrub.gsub(/[[:cntrl:]]/, '?')

    def canonical(value) = Tamoz::Core.canonical(value)
    def digest_of(domain, value) = "sha256:#{Digest::SHA256.hexdigest(domain + value)}"

    # Built once at load: a constant cannot be raced the way a memoized module variable can.
    EMPTY = compile(sources: [])
  end
end
