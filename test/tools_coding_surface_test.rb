# frozen_string_literal: true

require_relative 'test_helper'

class ToolsCodingSurfaceTest < Minitest::Test
  def with_workspace(checks: {})
    Dir.mktmpdir('tamoz-coding-surface') do |root|
      FileUtils.mkdir_p(File.join(root, 'lib/deep'))
      FileUtils.mkdir_p(File.join(root, 'node_modules/pkg'))
      File.write(File.join(root, 'lib/a.rb'), "def alpha\n  1\nend\n")
      File.write(File.join(root, 'lib/deep/b.rb'), "def beta_2\n  2\nend\n")
      File.write(File.join(root, 'node_modules/pkg/c.rb'), "def gamma\nend\n")
      File.write(File.join(root, 'notes.md'), "alpha\n")
      yield Tamoz::Tools::Toolbox.new(root:, allow_changes: true, checks:), root
    end
  end

  def test_glob_finds_files_and_skips_ignored_directories
    with_workspace do |toolbox, _|
      assert_equal "lib/a.rb\nlib/deep/b.rb", toolbox.execute('glob', 'pattern' => '**/*.rb')
      assert_equal 'lib/deep/b.rb', toolbox.execute('glob', 'pattern' => '*.rb', 'path' => 'lib/deep')
    end
  end

  # F7: the model's picture of the new file is the old read plus this diff, so the diff must carry
  # enough surrounding lines to place the change. DSH's card uses three (DIFF_CONTEXT = 3).
  # rubocop:disable Minitest/MultipleAssertions -- one property (the hunk header, the change and
  # the three context lines either side) observed in one place.
  def test_render_diff_carries_three_context_lines_either_side
    with_workspace do |toolbox, root|
      file = File.join(root, 'lib/context.rb')
      File.write(file, (1..12).map { |n| "line #{n}\n" }.join)
      patch = toolbox.__send__(:prepare_patch, 'path' => 'lib/context.rb',
                                               'expected_sha256' => Digest::SHA256.hexdigest(File.read(file)),
                                               'before' => "line 6\n", 'after' => "line 6 changed\n")

      diff = toolbox.__send__(:render_diff, 'lib/context.rb', patch)
      context = diff.lines.grep(/\A /).map { |line| line[1..].strip }

      assert_includes diff, '@@ -6,1 +6,1 @@'
      assert_includes diff, "-line 6\n"
      assert_includes diff, "+line 6 changed\n"
      assert_equal ['line 3', 'line 4', 'line 5', 'line 7', 'line 8', 'line 9'], context
    end
  end
  # rubocop:enable Minitest/MultipleAssertions

  ESCAPES = ['../*', '{..,x}/*', '{/etc,x}/hosts', '\\../*', '.\\./*', '/etc/*', 'etclink/*', 'etclink/**/*',
             '{/,x}**/*'].freeze

  def test_glob_never_leaves_the_workspace
    with_workspace do |toolbox, root|
      File.symlink('/etc/hosts', File.join(root, 'lib/hosts.rb'))
      File.symlink('/etc', File.join(root, 'etclink'))
      File.write(File.join(File.dirname(root), 'SECRET_SIBLING.txt'), 'x') if File.writable?(File.dirname(root))
      outputs = ESCAPES.map { |pattern| toolbox.execute('glob', 'pattern' => pattern) }

      assert_equal ['No files.'], outputs.uniq
      refute_includes toolbox.execute('glob', 'pattern' => '**/*.rb'), 'hosts'
    ensure
      FileUtils.rm_f(File.join(File.dirname(root), 'SECRET_SIBLING.txt'))
    end
  end

  def test_regex_search_matches_patterns_and_literal_search_does_not
    with_workspace do |toolbox, _|
      assert_equal 'lib/deep/b.rb:1:def beta_2', toolbox.execute('search_text', 'query' => 'beta_\d', 'regex' => true)
      assert_equal 'No matches.', toolbox.execute('search_text', 'query' => 'beta_\d')
    end
  end

  def test_an_invalid_regex_is_an_argument_error
    with_workspace do |toolbox, _|
      assert_raises(Tamoz::Tools::ToolArgumentError) do
        toolbox.execute('search_text', 'query' => '(unclosed', 'regex' => true)
      end
    end
  end

  def test_ranged_read_numbers_lines_and_digests_the_whole_file
    with_workspace do |toolbox, root|
      output = toolbox.execute('read_file', 'path' => 'lib/a.rb', 'offset' => 2, 'limit' => 1)
      digest = Digest::SHA256.hexdigest(File.read(File.join(root, 'lib/a.rb')))

      assert_equal "File: lib/a.rb\nsha256: #{digest}\nlines: 2-2 of 3\n2\t  1", output
    end
  end

  def test_a_file_too_large_to_read_whole_can_be_read_by_range
    with_workspace do |toolbox, root|
      File.write(File.join(root, 'big.txt'), "row\n" * 20_000)

      assert_raises(Tamoz::Tools::ToolArgumentError) { toolbox.execute('read_file', 'path' => 'big.txt') }
      assert toolbox.execute('read_file', 'path' => 'big.txt', 'offset' => 19_999).end_with?("19999\trow\n20000\trow")
    end
  end

  BAD_RANGES = [{ 'offset' => 0 }, { 'limit' => '5' }, { 'offset' => 10**30 }, { 'offset' => 50 }].freeze

  def test_range_arguments_must_be_bounded_integers_inside_the_file
    with_workspace do |toolbox, _|
      BAD_RANGES.each do |range|
        assert_raises(Tamoz::Tools::ToolArgumentError, range.inspect) do
          toolbox.execute('read_file', range.merge('path' => 'lib/a.rb'))
        end
      end
    end
  end

  def test_a_ranged_read_is_capped_like_a_whole_read_and_says_where_to_continue
    with_workspace do |toolbox, root|
      File.write(File.join(root, 'wide.txt'), "#{'x' * 40_000}\n" * 4)
      output = toolbox.execute('read_file', 'path' => 'wide.txt', 'offset' => 1)

      assert_operator output.bytesize, :<, Tamoz::Tools::Toolbox::MAX_FILE_BYTES + 512
      assert output.end_with?('... truncated; continue with offset 2')
    end
  end

  def test_a_catastrophic_regex_is_refused_not_hung
    with_workspace do |toolbox, root|
      File.write(File.join(root, 'slow.txt'), "#{'a' * 40}!\n")

      assert_raises(Tamoz::Tools::ToolArgumentError) do
        toolbox.execute('search_text', 'query' => '^(a+)+\\1$', 'regex' => true, 'path' => 'slow.txt')
      end
    end
  end

  def test_schemas_accept_exactly_what_the_validator_accepts
    with_workspace(checks: { 'test' => ['true'] }) do |toolbox, _|
      assert_equal %w[after before expected_sha256 path replacements],
                   toolbox.schemas.fetch('apply_patch').fetch('properties').keys.sort
      assert_equal %w[path expected_sha256], toolbox.schemas.fetch('apply_patch').fetch('required')
      assert_equal %w[content expected_sha256 mode path],
                   toolbox.schemas.fetch('create_file').fetch('properties').keys.sort
    end
  end

  def test_every_available_tool_has_a_closed_object_schema
    with_workspace(checks: { 'test' => ['true'] }) do |toolbox, _|
      schemas = toolbox.schemas

      assert_equal toolbox.names.sort, schemas.keys.sort
      assert(schemas.values.all? { |schema| schema['type'] == 'object' && schema['additionalProperties'] == false })
      assert_equal ['test'], schemas.fetch('run_check').dig('properties', 'name', 'enum')
    end
  end

  def test_a_passing_check_is_one_line_plus_its_tail_and_a_failure_keeps_everything
    stdout = "#{"noise\n" * 50}3 runs, 0 failures\n"
    passed = Tamoz::Tools::CheckReceipt.new(name: 'test', outcome: 'exit_0', stdout:, stderr: '')
    failed = Tamoz::Tools::CheckReceipt.new(name: 'test', outcome: 'exit_1', stdout: "trace\n" * 50, stderr: 'boom')

    assert_equal "Check test: exit_0 (passed)\n#{"noise\n" * 4}3 runs, 0 failures", passed.shaped
    assert_equal failed.to_s, failed.shaped
  end
end
