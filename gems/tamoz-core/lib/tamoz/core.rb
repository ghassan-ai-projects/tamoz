# frozen_string_literal: true

require "zeitwerk"
require_relative "core/version"

module Tamoz
  module Core
    ROOT = File.expand_path("../../..", __dir__).freeze

    loader = Zeitwerk::Loader.new
    loader.tag = "tamoz-core"
    loader.push_dir(File.expand_path("..", __dir__))
    loader.ignore(__FILE__)
    loader.ignore(File.expand_path("core/version.rb", __dir__))
    loader.setup
    loader.eager_load
    @loader = loader
  end
end
