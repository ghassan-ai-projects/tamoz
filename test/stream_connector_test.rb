# frozen_string_literal: true

require_relative "test_helper"
require_relative "stream_simulated_connector"

# P14-D/C4 (plan §3) — the golden auth-failure cases against the SIMULATED
# connector implementing the production contract: wrong key, forged identity,
# and replayed credential are all durably rejected (never admitted, never
# silent). The connector zone never receives model/tool/effector credentials.
class StreamConnectorTest < Minitest::Test
  Stream = Tamoz::Stream

  def test_wrong_key_is_rejected_durably
    connector = SimulatedSourceConnector.new(credentials: {"sensor-ca:device-428" => "secret-1"})
    error = assert_raises(Stream::AuthenticationError) do
      connector.authenticate("sensor-ca:device-428", "wrong-secret")
    end
    assert_equal :wrong_key, error.reason
    assert_equal 0, connector.accepted_credentials.length
    assert_equal 1, connector.rejected_credentials.length
  end

  def test_forged_identity_is_rejected_durably
    connector = SimulatedSourceConnector.new(credentials: {"sensor-ca:device-428" => "secret-1"})
    error = assert_raises(Stream::AuthenticationError) do
      connector.authenticate("attacker:device-999", "secret-1")
    end
    assert_equal :forged_identity, error.reason
    assert_equal 0, connector.accepted_credentials.length
  end

  def test_replayed_credential_is_rejected_durably
    connector = SimulatedSourceConnector.new(credentials: {"sensor-ca:device-428" => "secret-1"})
    session = connector.authenticate("sensor-ca:device-428", "secret-1")
    assert session.is_a?(Stream::SourceSession)

    error = assert_raises(Stream::AuthenticationError) do
      connector.authenticate_once("sensor-ca:device-428", "secret-1")
    end
    assert_equal :replayed_credential, error.reason
    # One accepted (the first), one durably rejected replay.
    assert_equal 1, connector.accepted_credentials.length
    assert_equal 1, connector.rejected_credentials.length
  end

  def test_valid_credentials_open_a_bounded_read_session
    connector = SimulatedSourceConnector.new(credentials: {"sensor-ca:device-428" => "secret-1"})
    session = connector.authenticate("sensor-ca:device-428", "secret-1")
    assert_kind_of SimulatedSourceSession, session
  end
end
