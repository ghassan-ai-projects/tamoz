# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class AttachmentTextTest < Minitest::Test
  Text = Tamoz::Agent::AttachmentText
  PDF = "%PDF-1.4\n%fixture\n".b

  def with_pdftotext(body)
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'pdftotext')
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
      yield path
    end
  end

  def test_utf8_text_is_read_as_sent_and_binary_is_refused
    assert_equal [:read, 'مرحبا notes'], Text.read('مرحبا notes'.b).to_h.values_at(:outcome, :text)
    assert_equal :unsupported_format, Text.read("PK\x03\x04\xFF".b).outcome
    assert_equal :unsupported_format, Text.read("text\x00with nul".b).outcome
  end

  def test_a_pdf_text_layer_is_read_with_its_page_count
    with_pdftotext(%(printf 'first page\\fsecond page\\f')) do |command|
      result = Text.read(PDF, pdftotext: command)

      assert_equal [:read, "first page\fsecond page", 2], result.to_h.values_at(:outcome, :text, :pages)
    end
  end

  def test_presentation_forms_are_normalized
    with_pdftotext(%(printf '\\357\\273\\213\\357\\273\\244\\f')) do |command|
      assert_equal 'عم', Text.read(PDF, pdftotext: command).text
    end
  end

  def test_a_pdf_without_a_text_layer_says_so
    with_pdftotext(%(printf '\\f\\f  \\f')) do |command|
      assert_equal :no_text_layer, Text.read(PDF, pdftotext: command).outcome
    end
  end

  def test_a_failing_reader_is_unreadable
    with_pdftotext('echo partial; exit 1') do |command|
      assert_equal :unreadable, Text.read(PDF, pdftotext: command).outcome
    end
  end

  def test_a_reader_past_its_deadline_is_killed_with_its_children
    Dir.mktmpdir do |directory|
      child = File.join(directory, 'child.pid')
      with_pdftotext("sleep 30 & echo $! > #{child}; wait") do |command|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_equal :unreadable, Text.read(PDF, pdftotext: command, seconds: 0.3).outcome
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
        assert gone?(File.read(child).to_i), 'the reader\'s own child is killed too'
      end
    end
  end

  # Killed, the orphan is reaped by init shortly after; until then it is a zombie that still answers kill(0).
  def gone?(pid)
    20.times do
      Process.kill(0, pid)
      Thread.pass
      IO.select(nil, nil, nil, 0.05)
    end
    false
  rescue Errno::ESRCH
    true
  end

  def test_a_reader_that_closes_its_output_and_hangs_is_killed
    with_pdftotext('exec 1>&-; sleep 30') do |command|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_equal :unreadable, Text.read(PDF, pdftotext: command, seconds: 0.3).outcome
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end
  end

  def test_a_reader_that_cannot_be_executed_is_named_missing
    with_pdftotext('true') do |command|
      File.chmod(0o644, command)

      assert_equal :pdf_reader_missing, Text.read(PDF, pdftotext: command).outcome
    end
  end

  def test_the_reader_never_sees_the_workers_credentials
    with_pdftotext('printf "%s\\f" "${ZAI_API_KEY:-none}"') do |command|
      ENV['ZAI_API_KEY'] = 'secret-key'

      assert_equal 'none', Text.read(PDF, pdftotext: command).text
    ensure
      ENV.delete('ZAI_API_KEY')
    end
  end

  def test_a_flood_of_output_is_cut_at_its_bound
    with_pdftotext('yes page') do |command|
      result = Text.read(PDF, pdftotext: command)

      assert_equal :read, result.outcome
      assert_operator result.text.bytesize, :<=, Text::PDF_OUTPUT_BYTES
    end
  end

  def test_a_missing_reader_is_named
    assert_equal :pdf_reader_missing, Text.read(PDF, pdftotext: '/nonexistent/pdftotext').outcome
  end
end
