# frozen_string_literal: true

module McpServerFixture
  private

  def build_config(answer_file, **overrides)
    Tamoz::Mcp::ServerConfig.new(
      server_id: 'test-server', transport: :stdio, command: RbConfig.ruby,
      arguments: [self.class::SERVER_SCRIPT, answer_file], working_directory: @dir,
      env_allowlist: self.class::BASE_ENV_ALLOWLIST + self.class::FLAG_NAMES,
      **overrides
    )
  end
end
