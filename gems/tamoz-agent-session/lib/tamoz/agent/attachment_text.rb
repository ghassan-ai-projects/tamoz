# frozen_string_literal: true

require 'tmpdir'

module Tamoz
  module Agent
    # The text of a received document: UTF-8 text as sent, a PDF's text layer through poppler's `pdftotext`.
    module AttachmentText
      Result = Data.define(:outcome, :text, :pages)

      PDF_MAGIC = '%PDF-'.b
      PDF_PAGES = 200
      PDF_SECONDS = 20
      PDF_OUTPUT_BYTES = 2_000_000
      READ_BYTES = 65_536
      KEPT_CHARACTERS = 100_000

      module_function

      def read(bytes, pdftotext: 'pdftotext', seconds: PDF_SECONDS)
        return pdf(bytes, pdftotext, seconds) if bytes.b.start_with?(PDF_MAGIC)

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return Result.new(:unsupported_format, nil, nil) unless text.valid_encoding? && !text.include?("\0")

        Result.new(:read, text[0, KEPT_CHARACTERS].unicode_normalize(:nfc), nil)
      end

      def pdf(bytes, command, seconds)
        Dir.mktmpdir('tamoz-attachment') do |directory|
          path = File.join(directory, 'attachment.pdf')
          File.binwrite(path, bytes)
          outcome, output = extract(command, path, seconds)
          next Result.new(outcome, nil, nil) unless outcome == :read

          text = output.force_encoding(Encoding::UTF_8).scrub('').unicode_normalize(:nfkc)
          next Result.new(:no_text_layer, nil, nil) if text.delete("\f").strip.empty?

          Result.new(:read, text.delete_suffix("\f"), text.count("\f"))
        end
      end

      # The PDF is read in its own process group with only PATH and a locale, CPU-limited and killed at the wall
      # clock, so a hostile file costs at most `seconds` and never the worker (or its credentials).
      def extract(command, path, seconds)
        reader, writer = IO.pipe
        deadline = clock + seconds
        pid = Process.spawn({ 'PATH' => ENV.fetch('PATH', ''), 'LANG' => 'C.UTF-8' }, command, '-q', '-enc', 'UTF-8',
                            '-l', PDF_PAGES.to_s, path, '-', unsetenv_others: true, in: File::NULL, out: writer,
                                                             err: File::NULL, pgroup: true, rlimit_cpu: PDF_SECONDS)
        writer.close
        output, finished = drained(reader, deadline)
        stop(pid) unless finished == :eof
        status = reaped(pid, deadline)
        pid = nil
        return [:unreadable, nil] unless finished == :limit || (finished == :eof && status.success?)

        [:read, output]
      rescue Errno::ENOENT, Errno::EACCES
        [:pdf_reader_missing, nil]
      rescue SystemCallError
        [:unreadable, nil]
      ensure
        reader&.close
        writer&.close unless writer.nil? || writer.closed?
        abandon(pid) if pid
      end

      def drained(reader, deadline)
        output = (+'').b
        loop do
          return [output, :timeout] unless reader.wait_readable([deadline - clock, 0].max)

          chunk = reader.read_nonblock(READ_BYTES, exception: false)
          return [output, :eof] if chunk.nil?
          next if chunk == :wait_readable

          output << chunk
          return [output.byteslice(0, PDF_OUTPUT_BYTES), :limit] if output.bytesize > PDF_OUTPUT_BYTES
        end
      end

      # A reader that closed its output and kept running is killed at the same deadline.
      def reaped(pid, deadline)
        loop do
          _pid, status = Process.wait2(pid, Process::WNOHANG)
          return status if status
          return stop(pid) && Process.wait2(pid).last if clock > deadline

          sleep 0.01
        end
      end

      def abandon(pid)
        stop(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      def stop(pid)
        Process.kill('KILL', -pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        true
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
