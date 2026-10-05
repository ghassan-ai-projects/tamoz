# frozen_string_literal: true

module RuntimeCliFixture
  def cli(argv)
    out = StringIO.new
    err = StringIO.new
    exit_code = Tamoz::Agent::CLI.run(
      ['--runtime-dir', dir] + argv,
      out:, err:, input: StringIO.new,
      env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' }
    )
    [exit_code, out.string, err.string]
  end
end
