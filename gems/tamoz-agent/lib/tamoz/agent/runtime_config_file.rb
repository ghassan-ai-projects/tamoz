# frozen_string_literal: true

require 'psych'

module Tamoz
  module Agent
    class RuntimeDirectory
      # The operator's config file on disk: its one default write, and every later edit landing whole —
      # validated first, the original kept as a backup, the new file in place by atomic rename.
      module ConfigFile
        module_function

        def path(directory) = File.join(directory, CONFIG_FILE)

        def read(config_path) = Psych.safe_load_file(config_path, permitted_classes: [], aliases: false)

        def write_default!(directory, workspace:, models:)
          document = { 'runtime' => { 'schema_version' => SCHEMA_VERSION },
                       'workspace' => { 'root' => File.expand_path(workspace) }, 'sources' => {}, 'channels' => {} }
          document['models'] = models unless models.empty?
          Tamoz::Core::AtomicFile.create(path(directory), Psych.dump(document), mode: 0o600)
        rescue Errno::EEXIST
          nil
        end

        # Yields the current document; returns the backup of the replaced file, or nil when the edit changed
        # nothing. A refused edit leaves the file untouched.
        def edit!(directory)
          config_path = path(directory)
          edited = yield(read(config_path))
          return nil if edited == read(config_path)

          ConfigRules.validate_document!(edited)
          backup = "#{config_path}.bak-#{Time.now.utc.strftime('%Y%m%dT%H%M%S.%6NZ')}"
          Tamoz::Core::AtomicFile.create(backup, File.binread(config_path), mode: 0o600)
          Tamoz::Core::AtomicFile.replace(config_path, Psych.dump(edited), mode: 0o600)
          backup
        end
      end
    end
  end
end
