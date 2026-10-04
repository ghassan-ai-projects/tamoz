# frozen_string_literal: true

module WorkerRuntimeFixture
  private

  def open_runtime(directory)
    runtime = Tamoz::Agent::WorkerRuntime.open(
      Tamoz::Agent::RuntimeDirectory.resolve(path: directory.dir, env: {}),
      model_factory: ->(profile:) { read_only_factory.call(profile) }
    )
    yield runtime
  ensure
    runtime&.close
  end
end
