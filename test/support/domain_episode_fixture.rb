# frozen_string_literal: true

module DomainEpisodeFixture
  private

  def run_episode(episode_id:, document:, allowed:, risk_ceiling:, snapshot: self.class::Domain.snapshot)
    domain = self.class::Domain
    endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: [Tamoz::Core.jcs(document)],
      log_path: File.join(@dir, "#{episode_id}.log")
    ).start
    @endpoints << endpoint
    composition = EpisodeComposition.build(endpoint: endpoint.base_url)
    @compositions << composition
    request = EpisodeComposition.wire_request(
      episode_id:, prompt: domain::PROMPT, snapshot:,
      catalog_json: Tamoz::Core.jcs(domain::CATALOG),
      intent_catalog_json: Tamoz::Core.jcs(domain::INTENT_CATALOG),
      intent_catalog_sha256: domain.intent_catalog_digest,
      objective: domain::OBJECTIVE,
      allowed_intent_types: allowed, risk_ceiling:
    )
    events, app = EpisodeComposition.run(composition, request)
    terminal = events.filter_map(&:terminal).last
    [terminal, decision_for(app, episode_id, terminal)]
  end

  def decision_for(app, episode_id, terminal)
    return nil unless terminal&.status == :TERMINAL_STATUS_PRODUCED

    result = app.durable_runner.fetch(
      thread: "episode.#{episode_id}",
      request_id: "episode.#{episode_id}.at-1.1",
      namespace: ['acme']
    )
    app.state(thread: "episode.#{episode_id}", namespace: ['acme'], checkpoint_id: result.checkpoint_id)
       .state.to_h.fetch(:decision)
  end
end
