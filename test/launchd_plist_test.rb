# frozen_string_literal: true

require_relative 'test_helper'

# A launchd job rendered as plist XML: every value escaped, keys sorted, the restart policy fixed.
class LaunchdPlistTest < Minitest::Test
  def plist(environment: { 'B_KEY' => 'b', 'A_KEY' => 'a<&>"' })
    Tamoz::Agent::LaunchdPlist.render(label: 'com.tamoz.worker', arguments: ['/usr/bin/ruby', 'tamoz', 'a&b'],
                                      environment:, directory: '/runtime', log: '/runtime/logs/worker.log')
  end

  def test_values_are_escaped
    assert_includes plist, '<key>A_KEY</key><string>a&lt;&amp;&gt;&quot;</string>'
    assert_includes plist, '<string>a&amp;b</string>'
  end

  def test_environment_keys_are_sorted_so_the_file_is_stable
    assert_operator plist.index('A_KEY'), :<, plist.index('B_KEY')
  end

  def test_the_job_restarts_with_a_throttle
    assert_includes plist, '<key>KeepAlive</key><true/>'
    assert_includes plist, '<key>ThrottleInterval</key><integer>30</integer>'
  end

  def test_it_is_a_well_formed_plist
    require 'rexml/document'

    assert_equal 'plist', REXML::Document.new(plist).root.name
  end
end
