# frozen_string_literal: true

require 'fileutils'
require 'optparse'

module Tamoz
  module Agent
    # `tamoz service install|status|uninstall`: a runtime's gateways and worker as launchd jobs, one per child.
    module CLIServiceCommands
      SERVICE_USAGE = 'usage: tamoz service install --env-file PATH | status | uninstall'

      def cmd_service(options, argv)
        verb, *rest = argv
        case verb
        when 'install' then service_install(options, rest)
        when 'status' then service_status(options)
        when 'uninstall' then service_uninstall(options)
        when '-h', '--help', nil then service_usage(verb ? 0 : 1)
        else raise OptionParser::InvalidArgument, SERVICE_USAGE
        end
      end

      private

      def service_usage(status)
        @out.puts SERVICE_USAGE
        status
      end

      def service_install(options, argv)
        request = start_request(argv)
        raise OptionParser::MissingArgument, '--env-file (launchd reads no .env)' unless request[:env_file]

        problem = env_file_problem(request[:env_file])
        return start_fail(problem) if problem

        base = start_env(request)
        directory = RuntimeDirectory.resolve(path: runtime_dir_path(options), env: base)
        problem = start_problem(options, directory, base)
        return start_fail(problem) if problem

        install_jobs(directory, base.merge(talk_token_env(directory)).merge(child_runtime_env))
      end

      def install_jobs(directory, base)
        backup = back_up_jobs(directory)
        FileUtils.mkdir_p(launch_agents)
        plists = child_plan(directory, base).map { |name, (env, args)| write_job(directory, name, env, args) }
        failed = load_jobs(plists)
        return start_fail("launchctl could not load #{failed.join('; ')}") if failed.any?

        @out.puts "Installed #{plists.length} jobs: #{plists.map { job_label(_1) }.join(', ')}."
        @out.puts "Earlier plists were moved to #{backup}." if backup
        0
      end

      def load_jobs(plists)
        plists.filter_map do |plist|
          out, status = launchctl('bootstrap', "gui/#{Process.uid}", plist)
          "#{job_label(plist)} (#{out.strip})" unless status&.success?
        end
      end

      def write_job(directory, name, env, args)
        path = File.join(launch_agents, "#{CLILaunchd::LABEL_PREFIX}#{name}.plist")
        logs = File.join(directory.path, 'logs')
        Tamoz::Core::PrivateDirectory.secure(logs)
        plist = LaunchdPlist.render(label: "#{CLILaunchd::LABEL_PREFIX}#{name}", directory: directory.path,
                                    arguments: [RbConfig.ruby, CLIChildProcesses::EXE, '--runtime-dir', directory.path,
                                                *args],
                                    environment: env, log: File.join(logs, "#{name}.log"))
        Tamoz::Core::AtomicFile.replace(path, plist, mode: 0o600)
        path
      end

      def service_status(options)
        directory = RuntimeDirectory.resolve(path: runtime_dir_path(options), env: @env)
        chat = directory.models['chat']
        @out.puts "Runtime #{directory.path}: chat #{chat ? "#{chat.provider}/#{chat.model}" : 'not set'}; " \
                  "channels #{directory.channels.keys.join(', ')}"
        print_jobs(directory)
        0
      end

      def print_jobs(directory)
        labels = job_plists(directory).map { job_label(_1) }
        return @out.puts('No service is installed for this runtime.') if labels.empty?

        loaded = loaded_jobs
        labels.each { |label| @out.puts "  #{label}: #{loaded[label] ? "pid #{loaded[label]}" : 'not running'}" }
      end

      def service_uninstall(options)
        directory = RuntimeDirectory.resolve(path: runtime_dir_path(options), env: @env)
        backup = back_up_jobs(directory)
        @out.puts backup ? "Stopped and moved the service's plists to #{backup}." : 'No service is installed.'
        0
      end

      # Unloads this runtime's jobs and moves their plists aside; a job that stays loaded keeps its plist, so it is
      # still seen (and `start` still refuses) rather than running unseen.
      def back_up_jobs(directory)
        plists = job_plists(directory)
        return if plists.empty?

        plists.each { |plist| launchctl('bootout', "gui/#{Process.uid}/#{job_label(plist)}") }
        still_loaded = loaded_jobs.keys
        backup = File.join(directory.path, 'service-backups', Time.now.utc.strftime('%Y%m%dT%H%M%SZ'))
        FileUtils.mkdir_p(backup, mode: 0o700)
        plists.reject { still_loaded.include?(job_label(_1)) }.each { |plist| stash_plist(plist, backup) }
        backup
      end

      def stash_plist(plist, backup)
        Tamoz::Core::AtomicFile.create(File.join(backup, File.basename(plist)), File.read(plist), mode: 0o600)
        File.delete(plist)
      end
    end
  end
end
