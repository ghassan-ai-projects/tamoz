# frozen_string_literal: true

require 'cgi'

module Tamoz
  module Agent
    # One launchd job as plist XML: what it runs, with which environment, and where it logs.
    module LaunchdPlist
      HEADER = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
      XML
      # KeepAlive restarts a child that dies; ThrottleInterval stops a crash loop from spinning.
      POLICY = <<~XML
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>30</integer>
        <key>ExitTimeOut</key><integer>15</integer>
      XML

      def self.render(label:, arguments:, environment:, directory:, log:)
        [HEADER, string('Label', label), "<key>ProgramArguments</key>\n<array>\n",
         *arguments.map { |argument| "<string>#{escape(argument)}</string>\n" }, "</array>\n",
         "<key>EnvironmentVariables</key>\n<dict>\n",
         *environment.sort.map { |name, value| string(name, value) }, "</dict>\n",
         string('WorkingDirectory', directory), POLICY, string('StandardOutPath', log),
         string('StandardErrorPath', log), "</dict>\n</plist>\n"].join
      end

      def self.string(key, value) = "<key>#{escape(key)}</key><string>#{escape(value)}</string>\n"

      def self.escape(text) = CGI.escapeHTML(text.to_s)
    end
  end
end
