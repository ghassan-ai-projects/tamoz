# frozen_string_literal: true

require 'open3'

module Tamoz
  module Agent
    # What launchd runs for a runtime: the jobs whose plists name its folder, and which of them are loaded.
    module CLILaunchd
      LABEL_PREFIX = 'com.tamoz.'

      private

      def service_problem(directory)
        labels = job_plists(directory).map { job_label(_1) }
        return if labels.empty?

        running = labels & loaded_jobs.keys
        return if running.empty?

        "the service already runs this runtime (#{running.join(', ')}); stop it with `tamoz service uninstall`"
      end

      # A job serves this runtime when its plist names the runtime's folder.
      def job_plists(directory)
        needle = "<string>#{LaunchdPlist.escape(directory.path)}</string>"
        Dir[File.join(launch_agents, "#{LABEL_PREFIX}*.plist")].select { |path| File.read(path).include?(needle) }
      end

      # label => pid (nil when loaded but not running), from `launchctl list`, which never shows an environment.
      def loaded_jobs
        out, = launchctl('list')
        out.to_s.lines.filter_map do |line|
          pid, _status, label = line.split("\t").map(&:strip)
          [label, pid == '-' ? nil : pid] if label&.start_with?(LABEL_PREFIX)
        end.to_h
      end

      def job_label(plist) = File.basename(plist, '.plist')

      def launchctl(*)
        Open3.capture2e('launchctl', *)
      rescue Errno::ENOENT
        raise Error, 'launchctl was not found; `tamoz service` runs on macOS'
      end

      def launch_agents = File.join(Dir.home, 'Library', 'LaunchAgents')
    end
  end
end
