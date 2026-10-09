# frozen_string_literal: true

require 'psych'

# A real runtime directory whose config carries a `models:` section.
module RuntimeModelsFixture
  def runtime_with_models(root, models)
    workspace = File.join(root, 'workspace')
    FileUtils.mkdir_p(workspace)
    path = Tamoz::Agent::RuntimeDirectory.create!(File.join(root, 'runtime'), workspace:).path
    write_models(path, models)
    path
  end

  def write_models(path, models)
    config = File.join(path, Tamoz::Agent::RuntimeDirectory::CONFIG_FILE)
    File.write(config, Psych.dump(Psych.safe_load_file(config).merge('models' => models)))
  end
end
