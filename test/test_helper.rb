# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "stringio"
require "tmpdir"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
GEM_ROOTS = %w[tamoz-core tamoz-graph tamoz-sqlite tamoz-tools tamoz-agent tamoz-evals tamoz-mcp tamoz-scheduler tamoz-stream].to_h do |name|
  [name, ROOT.join("gems", name)]
end.freeze

GEM_ROOTS.each_value do |root|
  $LOAD_PATH.unshift(root.join("lib").to_s)
end

require "tamoz/core"
require "tamoz/graph"
require "tamoz/sqlite"
require "tamoz/tools"
require "tamoz/agent"
require "tamoz/evals"
require "tamoz/mcp"
require "tamoz/scheduler"
require "tamoz/stream"

module ArtifactHelpers
  def read_json(path)
    JSON.parse(File.read(path, encoding: Encoding::UTF_8))
  end

  def write_artifact(path, document, domain:)
    document["content_digest"] = Tamoz::Evals::CanonicalJSON.content_digest(document, domain:)
    File.write(
      path,
      "#{Tamoz::Evals::CanonicalJSON.dump(document)}\n",
      encoding: Encoding::UTF_8
    )
  end
end

class Minitest::Test
  include ArtifactHelpers
end
