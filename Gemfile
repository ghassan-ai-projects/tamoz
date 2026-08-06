# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.3", "< 5.0"

gem "mcp", "~> 1.1"
gem "minitest", "~> 6.0"
gem "rake", "~> 13.2"
gem "tamoz-agent", path: "gems/tamoz-agent"
gem "tamoz-core", path: "gems/tamoz-core"
gem "tamoz-tools", path: "gems/tamoz-tools"
gem "tamoz-mcp", path: "gems/tamoz-mcp"
gem "tamoz-evals", path: "gems/tamoz-evals"
gem "tamoz-graph", path: "gems/tamoz-graph"
gem "tamoz-sqlite", path: "gems/tamoz-sqlite"
gem "tamoz-scheduler", path: "gems/tamoz-scheduler"
gem "tamoz-stream", path: "gems/tamoz-stream"
gem "zeitwerk", "~> 2.6"

# Development/test-only quality tooling (Q0 of the quality program).
# NOTE: reek and rubocop-minitest are charter-listed but could not be installed
# while rubygems.org was unreachable (2026-08-06); add them back in a later slice.
group :development, :test do
  gem "rubocop", "~> 1.87"
  gem "rubocop-performance", "~> 1.25"
  gem "simplecov", "~> 0.22"
end
