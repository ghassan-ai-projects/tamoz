# frozen_string_literal: true

require "zeitwerk"
require "tamoz/core"
require_relative "graph/version"

module Tamoz
  module Graph
    ROOT = File.expand_path("../../..", __dir__).freeze

    loader = Zeitwerk::Loader.new
    loader.tag = "tamoz-graph"
    loader.push_dir(File.expand_path("..", __dir__))
    loader.ignore(__FILE__)
    loader.ignore(File.expand_path("graph/version.rb", __dir__))
    loader.setup
    loader.eager_load
    @loader = loader
  end

  def self.graph(name:, version:, &definition)
    raise ArgumentError, "a graph definition block is required" unless definition

    Graph.const_get(:Builder, false).build(name:, version:, &definition)
  end
end
