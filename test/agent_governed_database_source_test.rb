# frozen_string_literal: true

require_relative 'test_helper'

class AgentGovernedDatabaseSourceTest < Minitest::Test
  class Source
    attr_reader :calls

    def initialize
      @calls = []
    end

    def names = ['mcp:db/query', 'mcp:other/query']

    def execute(context, name, arguments)
      @calls << [context, name, arguments]
      'rows'
    end
  end

  def setup
    @source = Source.new
    @database = Tamoz::Agent::GovernedDatabaseSource.new(source: @source, server_id: 'db')
  end

  def test_only_operator_owned_server_capabilities_are_visible_and_queries_are_bounded
    assert_equal ['mcp:db/query'], @database.names
    assert_equal 'rows', @database.execute({}, 'mcp:db/query', 'query' => 'SELECT 1')
    assert_equal({ 'query' => 'SELECT 1', 'max_rows' => 1000 }, @source.calls.first.fetch(2))
  end

  def test_write_queries_and_other_servers_are_refused_before_dispatch
    assert_raises(Tamoz::Agent::ToolPolicyError) { @database.execute({}, 'mcp:db/query', 'query' => 'DELETE FROM users') }
    assert_raises(Tamoz::Agent::ToolPolicyError) { @database.execute({}, 'mcp:other/query', 'query' => 'SELECT 1') }
    assert_empty @source.calls
  end
end
