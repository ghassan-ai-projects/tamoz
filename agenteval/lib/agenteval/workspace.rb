# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module Agenteval
  # The workspace the agent is given, plus everything needed to judge what it did to it.
  #
  # Verification never runs inside the workspace the agent touched: hidden tests are
  # overlaid onto a *copy*. An agent cannot read, edit, or fit an oracle it never sees.
  class Workspace
    attr_reader :dir, :answer, :exit_code, :timed_out

    def initialize(dir)
      @dir = dir
      @initial = {}
      @answer = ""
      @exit_code = nil
      @timed_out = false
    end

    def materialize(files)
      files.each do |relative, content|
        path = File.join(@dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      @initial = snapshot
    end

    # Write files AFTER the baseline snapshot, so they register as the agent's mutations.
    # This is how the validator applies a reference solution: it has to look like work the
    # agent did, or an oracle that asks "did anything change" reports the task unreachable.
    def agent_wrote(files)
      files.each do |relative, content|
        path = File.join(@dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
    end

    def record_run(answer:, exit_code:, timed_out:)
      @answer = answer.to_s
      @exit_code = exit_code
      @timed_out = timed_out
    end

    # Content digest plus modification time, per file.
    #
    # A digest alone cannot see a write that was undone: an agent that rewrites a read-only
    # file and puts the original bytes back leaves the content identical, so a read-only
    # violation is invisible. The mtime survives the round trip, which is what makes the
    # read-only check an observation rather than an after-the-fact comparison.
    def snapshot
      Dir.glob(File.join(@dir, "**", "*"), File::FNM_DOTMATCH)
         .reject { |path| File.directory?(path) }
         .each_with_object({}) do |path, map|
        relative = path.delete_prefix("#{@dir}/")
        next if relative.start_with?(".git/")

        stat = File.stat(path)
        map[relative] = [Digest::SHA256.hexdigest(File.binread(path)), stat.mtime.to_f]
      end
    end

    def changed
      current = snapshot
      (@initial.keys & current.keys).reject { |key| @initial[key] == current[key] }.sort
    end

    def created = (snapshot.keys - @initial.keys).sort

    def deleted = (@initial.keys - snapshot.keys).sort

    def mutations = (changed + created + deleted).uniq.sort

    def exist?(relative) = File.exist?(File.join(@dir, relative))

    def read(relative)
      path = File.join(@dir, relative)
      return nil unless File.exist?(path)

      # An agent may leave any bytes behind; reading must never raise on the scoring path.
      File.binread(path).force_encoding(Encoding::UTF_8).scrub("?")
    end

    # Run a command against a COPY of the post-agent workspace, optionally overlaying
    # hidden files (acceptance tests, mutants) that the agent never had access to.
    def verify_with(overlay: {}, command:, timeout: 120)
      Dir.mktmpdir("agenteval-verify") do |scratch|
        target = File.join(scratch, "w")
        FileUtils.cp_r(@dir, target)
        overlay.each do |relative, content|
          path = File.join(target, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end
        run(command, chdir: target, timeout:)
      end
    end

    # A verification run has two ways to outlive its usefulness, and both are
    # bounded here: the process tree (a suite that spawns its own children left
    # them running under a tmpdir this method is about to delete) and the
    # captured output (a runaway suite printing forever is a memory exhaustion,
    # not a test failure).
    OUTPUT_LIMIT_BYTES = 1024 * 1024

    def run(command, chdir:, timeout: 120)
      out = +""
      status = nil
      env = {"LC_ALL" => "en_US.UTF-8", "LANG" => "en_US.UTF-8"}
      Open3.popen2e(env, *command, chdir:, pgroup: true) do |stdin, stream, waiter|
        stdin.close
        reader = Thread.new { read_bounded(stream, out) }
        unless waiter.join(timeout)
          kill_tree(waiter.pid)
          reader.join(2)
          return CommandResult.new(ok: false, output: "#{out}\n[agenteval] timed out after #{timeout}s", timed_out: true)
        end
        reader.join(5)
        status = waiter.value
      end
      CommandResult.new(ok: status&.success? || false, output: out, timed_out: false)
    end

    private

    def read_bounded(stream, out)
      while (chunk = stream.read(16_384))
        remaining = OUTPUT_LIMIT_BYTES - out.bytesize
        if remaining <= 0
          out << "\n[agenteval] output truncated at #{OUTPUT_LIMIT_BYTES} bytes"
          break
        end
        out << (chunk.bytesize > remaining ? chunk.byteslice(0, remaining) : chunk)
      end
    rescue IOError
      # the stream closed under us when the child was killed
    end

    # The child owns its own process group (`pgroup: true` above), so the group
    # kill reaches the suite's own children too. The single-pid kill is the
    # fallback for a child that already exited.
    def kill_tree(pid)
      Process.kill("KILL", -Process.getpgid(pid))
    rescue StandardError
      begin
        Process.kill("KILL", pid)
      rescue StandardError
        nil
      end
    end
  end

  CommandResult = Struct.new(:ok, :output, :timed_out, keyword_init: true)
end
