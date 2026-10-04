# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'support/test_suite'

class TestSuiteTest < Minitest::Test
  def test_discovers_each_test_root_once_and_ignores_support_files
    paths = %w[test/nested/root_test.rb gems/subject/test/gem_test.rb agenteval/test/grader_test.rb]

    with_sources(paths.to_h { |path| [path, ''] }.merge('test/support/helper.rb' => '')) do |root|
      assert_equal paths.sort, TestSuite.files(root:)
    end
  end

  def test_syntax_inventory_includes_evaluation_sources_and_gem_executables
    paths = %w[Rakefile test/support/helper.rb gems/subject/lib/subject.rb gems/subject/exe/subject
               agenteval/lib/grader.rb]

    with_sources(paths.to_h { |path| [path, ''] }.merge('agenteval/README.md' => '')) do |root|
      assert_equal paths.sort, TestSuite.sources(root:)
    end
  end

  def test_lanes_cover_the_inventory_once_and_keep_manual_and_milestone_separate
    paths = %w[test/fast_test.rb test/slow_test.rb test/serial_test.rb test/milestone_test.rb test/manual_test.rb]
    with_sources(paths.to_h { |path| [path, ''] }) do |root|
      lanes = TestSuite.lanes(root:, slow: [paths[1]], serial: [paths[2]],
                              autonomy: [paths[3]], manual: [paths[4]])

      expected = { fast: [paths[0]], slow: [paths[1]], serial: [paths[2]],
                   autonomy: [paths[3]], manual: [paths[4]] }

      assert_equal expected, lanes
    end
  end

  def test_missing_lane_entry_fails_instead_of_silently_disappearing
    with_sources({}) do |root|
      error = assert_raises(ArgumentError) do
        TestSuite.lanes(root:, slow: ['test/missing_test.rb'], serial: [], autonomy: [], manual: [])
      end

      assert_equal 'missing lane files: test/missing_test.rb', error.message
    end
  end

  def test_repeated_file_within_a_lane_is_rejected
    with_sources('test/slow_test.rb' => '') do |root|
      error = assert_raises(ArgumentError) do
        TestSuite.lanes(root:, slow: ['test/slow_test.rb'] * 2, serial: [], autonomy: [], manual: [])
      end

      assert_equal 'duplicate lane files: test/slow_test.rb', error.message
    end
  end

  def test_a_file_cannot_belong_to_both_slow_and_serial_lanes
    with_sources('test/slow_test.rb' => '') do |root|
      error = assert_raises(ArgumentError) do
        TestSuite.lanes(root:, slow: ['test/slow_test.rb'], serial: ['test/slow_test.rb'], autonomy: [], manual: [])
      end

      assert_equal 'duplicate lane files: test/slow_test.rb', error.message
    end
  end

  def test_duplicate_test_classes_across_roots_fail_before_loading
    source = 'class SubjectTest < Minitest::Test; def test_result; end; end'
    paths = %w[test/subject_test.rb gems/subject/test/subject_test.rb]
    with_sources(paths.to_h { |path| [path, source] }) do |root|
      error = assert_raises(ArgumentError) { TestSuite.validate_identities!(paths, root:) }

      assert_equal "duplicate test class SubjectTest: #{paths.join(', ')}", error.message
    end
  end

  def test_duplicate_methods_in_one_class_cannot_silently_overwrite_a_case
    source = 'class SubjectTest < Minitest::Test; def test_result; end; def test_result; end; end'
    with_sources('test/subject_test.rb' => source) do |root|
      error = assert_raises(ArgumentError) { TestSuite.validate_identities!(TestSuite.files(root:), root:) }

      assert_equal 'duplicate test method SubjectTest#test_result: test/subject_test.rb, test/subject_test.rb',
                   error.message
    end
  end

  def test_reopening_a_test_class_without_a_superclass_is_rejected
    with_sources('test/one_test.rb' => 'class SubjectTest < Minitest::Test; end',
                 'test/two_test.rb' => 'class SubjectTest; def test_result; end; end') do |root|
      error = assert_raises(ArgumentError) { TestSuite.validate_identities!(TestSuite.files(root:), root:) }

      assert_equal 'duplicate test class SubjectTest: test/one_test.rb, test/two_test.rb', error.message
    end
  end

  def test_duplicate_literal_generated_methods_cannot_overwrite_a_case
    source = <<~RUBY_SOURCE
      class SubjectTest < Minitest::Test
        define_method(:test_result) { assert true }
        define_method('test_result') { assert false }
      end
    RUBY_SOURCE
    with_sources('test/subject_test.rb' => source) do |root|
      error = assert_raises(ArgumentError) { TestSuite.validate_identities!(TestSuite.files(root:), root:) }

      assert_includes error.message, 'duplicate test method SubjectTest#test_result'
    end
  end

  def test_same_local_test_name_in_distinct_namespaces_is_valid
    source = 'module %s; class SubjectTest < Minitest::Test; def test_result; end; end; end'

    with_sources('test/one_test.rb' => format(source, 'One'), 'test/two_test.rb' => format(source, 'Two')) do |root|
      assert_silent { TestSuite.validate_identities!(TestSuite.files(root:), root:) }
    end
  end

  def test_comments_and_helper_method_names_are_not_test_definitions
    source = <<~RUBY_SOURCE
      # class SubjectTest < Minitest::Test; def test_result; end; end
      class SubjectTest < Minitest::Test
        def helper; end
        def helper; end
        def test_result; end
      end
    RUBY_SOURCE
    with_sources('test/subject_test.rb' => source) do |root|
      assert_silent { TestSuite.validate_identities!(TestSuite.files(root:), root:) }
    end
  end

  def test_invalid_source_cannot_receive_a_successful_identity_audit
    with_sources('test/subject_test.rb' => 'class SubjectTest <') do |root|
      error = assert_raises(ArgumentError) { TestSuite.validate_identities!(TestSuite.files(root:), root:) }

      assert_equal 'invalid Ruby test source: test/subject_test.rb', error.message
    end
  end

  def test_runner_treats_spaces_and_shell_punctuation_as_literal_file_names
    with_sources("test/space 'quote';literal_test.rb" => "puts 'loaded literal path'") do |root|
      path = File.join(root, "test/space 'quote';literal_test.rb")
      script = 'load ARGV.shift; exit(system(*test_command([ARGV.shift])) ? 0 : 1)'
      output, status = Open3.capture2e(RbConfig.ruby, '-rrake', '-e', script,
                                       File.join(TestSuite::ROOT, 'Rakefile'), path, chdir: TestSuite::ROOT)

      assert_predicate status, :success?, output
      assert_equal "loaded literal path\n", output
    end
  end

  def test_repository_test_identities_are_unique
    assert_silent { TestSuite.validate_identities!(TestSuite.files) }
  end

  private

  def with_sources(sources)
    Dir.mktmpdir('test-suite') do |root|
      sources.each do |path, source|
        absolute = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, source)
      end
      yield root
    end
  end
end
