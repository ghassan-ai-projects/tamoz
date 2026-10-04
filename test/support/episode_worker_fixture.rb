# frozen_string_literal: true

module EpisodeWorkerFixture
  private

  def worker
    Tamoz::Stream::EpisodeWorker.new(
      worker_version: '0.1.0.alpha.1',
      lane_config: Tamoz::Agent::LaneConfig.build(
        'fast' => 'flash', 'deep' => 'pro', 'batch' => 'flash'
      )
    )
  end
end
