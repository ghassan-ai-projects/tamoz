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

  # No RUBYLIB, no RUBYOPT, and none of the BUNDLE*/BUNDLER* variables `bundle exec` exports: the
  # child resolves tamoz/* from the script's bootstrap alone, as a person running it from a shell does.
  BARE_ENV = ENV.keys.grep(/\ABUNDLE/).to_h { |key| [key, nil] }
                .merge('RUBYOPT' => nil, 'RUBYLIB' => nil).freeze

  # Named, not discovered. The probe RUNS each script, and `script/` also holds generators whose
  # whole job is to write committed artifacts — `generate_legacy_session_fixture` rewrites
  # test/fixtures/legacy_session_v1.sqlite3. A glob here would regenerate them as a side effect of
  # checking a load path.
  COVERED = %w[benchmark_holdout benchmark_release benchmark_run].freeze

  def bootstrapping_scripts
    COVERED.map { |name| ROOT.join('script', name) }.select(&:file?).select do |path|
      path.read.lines.any? { |line| line.include?('$LOAD_PATH') && line.include?('gems') }
    end
  end

  def run_script(path, args: [], env: BARE_ENV)
    out, err, status = Open3.capture3(env, RbConfig.ruby, path.to_s, *args, chdir: ROOT.to_s)
    [out, err, status]
  end

  # The stripped copy must die of the missing bootstrap, not of whatever the environment makes
  # resolvable: with bundler gone, an empty gem home is the only other place tamoz/* could come from.
  def without_gem_fallback(dir)
    BARE_ENV.merge('GEM_HOME' => File.join(dir, 'gem_home'), 'GEM_PATH' => File.join(dir, 'empty_gem_path'))
  end

  def test_the_probe_covers_the_benchmark_scripts
    names = bootstrapping_scripts.map { |path| path.basename.to_s }.sort

    assert_equal COVERED.sort, names,
                 'each covered script must still bootstrap gem libs, or this probe covers nothing for it'
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

      _out, err, status = run_script(copy, env: without_gem_fallback(dir))

      refute_predicate status, :success?, 'the stripped copy loaded anyway; the probe cannot detect the defect'
      assert_includes err, "#{STRIPPED_HARNESS} -- tamoz/",
                      "the stripped copy failed for the wrong reason:\n#{err}"
    end
  end
end
