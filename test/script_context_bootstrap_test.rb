# frozen_string_literal: true

require_relative 'test_helper'

# A benchmark script that hand-maintains a subset of gem lib dirs on its own
# $LOAD_PATH rots silently the moment a class moves into a new gem: the script
# still loads inside tests (the test process already has every gem on its path)
# and only dies when somebody runs it for real. So the property is behavioral —
# the script's own bootstrap must suffice to resolve its own requires — and it
# is checked against a stripped copy that must fail.
class ScriptContextBootstrapTest < Minitest::Test
  STRIPPED_HARNESS = 'cannot load such file'

  # No RUBYLIB, no bundler, no RUBYOPT: the child resolves tamoz/* from the
  # script's bootstrap alone, exactly as a person running it from a shell does.
  BARE_ENV = {
    'RUBYOPT' => nil, 'RUBYLIB' => nil,
    'BUNDLE_GEMFILE' => nil, 'BUNDLE_BIN_PATH' => nil
  }.freeze

  def bootstrapping_scripts
    ROOT.glob('script/*').select(&:file?).select do |path|
      path.read.lines.any? { |line| line.include?('$LOAD_PATH') && line.include?('gems') }
    end
  end

  def run_script(path, args: [])
    out, err, status = Open3.capture3(BARE_ENV, RbConfig.ruby, path.to_s, *args, chdir: ROOT.to_s)
    [out, err, status]
  end

  def test_the_probe_covers_the_benchmark_scripts
    names = bootstrapping_scripts.map { |path| path.basename.to_s }.sort

    %w[benchmark_holdout benchmark_release benchmark_run].each do |expected|
      assert_includes names, expected,
                      "#{expected} no longer bootstraps gem libs; this probe would cover nothing for it"
    end
  end

  def test_each_script_resolves_its_own_requires
    scripts = bootstrapping_scripts

    refute_empty scripts

    scripts.each do |path|
      _out, err, _status = run_script(path)

      refute_includes err, STRIPPED_HARNESS,
                      "#{path.basename} cannot load a gem from its own bootstrap:\n#{err}"
    end
  end

  def test_a_stripped_copy_of_a_script_does_fail_to_load
    source = ROOT.join('script', 'benchmark_holdout')
    stripped = source.read.lines.reject { |line| line.include?('$LOAD_PATH') }.join

    Dir.mktmpdir('tamoz-bootstrap') do |dir|
      copy = Pathname.new(dir).join('stripped_holdout')
      copy.write(stripped)

      _out, err, status = run_script(copy)

      refute_predicate status, :success?, 'the stripped copy loaded anyway; the probe cannot detect the defect'
      assert_includes err, "#{STRIPPED_HARNESS} -- tamoz/",
                      "the stripped copy failed for the wrong reason:\n#{err}"
    end
  end
end
