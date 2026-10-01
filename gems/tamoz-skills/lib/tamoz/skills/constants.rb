# frozen_string_literal: true

module Tamoz
  module Skills
    SNAPSHOT_FORMAT_VERSION = 1

    TRUSTS = %w[bundled operator workspace].freeze
    DECLARED_RISKS = %w[elevated guarded read_only].freeze
    DEFAULT_DECLARED_RISK = 'guarded'
    UNREADABLE_AREA = 'scripts'
    AREA_DIRECTORIES = %w[assets references scripts].freeze
    MANIFEST_BASENAME = 'SKILL.md'

    # A body may never contain this; the fence it opens is keyed by the tree digest (see Rendering).
    DELIMITER_SENTINEL = '<<<TAMOZ_SKILL'

    SOURCE_ID_PATTERN = /\A[a-z][a-z0-9_-]{0,31}\z/
    NAME_PATTERN = /\A(?!.*--)[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\z/
    # ASCII, never leading `.`: `..`, separators, NUL and whitespace are unconstructible.
    COMPONENT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
    # Printable ASCII: an author's tool name from any agent (`Read`, `Bash(git add:*)`).
    TOOL_PATTERN = /\A[A-Za-z][\x20-\x7E]{0,127}\z/
    METADATA_KEY_PATTERN = /\A[a-z][a-z0-9_.-]{0,63}\z/
    FRONTMATTER_TERMINATOR = /^---[ \t]*(?:\r?\n|\z)/

    TREE_DIGEST_DOMAIN = "tamoz.skill.tree.v1\n"
    MANIFEST_DIGEST_DOMAIN = "tamoz.skill.manifest.v1\n"
    DESCRIPTION_DIGEST_DOMAIN = "tamoz.skill.description.v1\n"
    CATALOG_DIGEST_DOMAIN = "tamoz.skill.catalog.v1\n"

    LIMITS = {
      max_sources: 8,
      max_skills_per_source: 64,
      max_manifest_bytes: 64 * 1024,
      max_frontmatter_bytes: 8 * 1024,
      max_body_bytes: 16 * 1024,
      max_description_chars: 1024,
      max_compatibility_chars: 500,
      max_resource_bytes: 256 * 1024,
      max_read_bytes: 16 * 1024,
      max_tree_bytes: 2 * 1024 * 1024,
      max_tree_entries: 512,
      max_depth: 8,
      max_extra_keys: 16,
      max_extra_bytes: 4 * 1024,
      max_metadata_pairs: 32,
      max_metadata_value_bytes: 256,
      max_requested_capabilities: 32
    }.freeze

    MAX_CATALOG_BYTES = 4096
    MAX_CATALOG_DESCRIPTION_BYTES = 320
    MAX_DETAIL_BYTES = 200
    BUNDLED_ROOT = File.expand_path('../../../skills', __dir__).freeze
  end
end
