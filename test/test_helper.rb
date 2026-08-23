# frozen_string_literal: true

require_relative 'support/simplecov_setup' if ENV['RUN_COVERAGE'] == '1'

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "stringio"
require "tmpdir"

ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
GEM_ROOTS = %w[tamoz-core tamoz-graph tamoz-sqlite tamoz-tools tamoz-agent-kernel tamoz-agent-healing tamoz-agent tamoz-approval tamoz-evals tamoz-mcp tamoz-scheduler tamoz-stream tamoz-comms tamoz-telegram tamoz-observability tamoz-otel].to_h do |name|
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
require "tamoz/approval"
require "tamoz/evals"
require "tamoz/mcp"
require "tamoz/scheduler"
require "tamoz/stream"
require "tamoz/comms"
require "tamoz/telegram"
require "tamoz/observability"
require "tamoz/otel"

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
