# frozen_string_literal: true

# P14-D/C4 — the SIMULATED ChannelConnector/SourceSession, implementing the
# production contract exactly (the seam a real adapter will implement). Lives
# in the test tree: production tamoz-stream never references it (the
# dependency-direction test proves production code cannot see the harness).
#
# Golden auth-failure cases (plan §3): wrong key, forged identity, and
# replayed credential -> AuthenticationError with a durable rejection record
# in the store — never a silent drop, never admission.
class SimulatedSourceConnector
  include Tamoz::Stream::ChannelConnector

  attr_reader :accepted_credentials, :rejected_credentials

  def initialize(credentials:)
    @credentials = credentials.dup.freeze
    @accepted_credentials = []
    @rejected_credentials = []
  end

  def authenticate(source_identity, credential)
    expected = @credentials[source_identity]
    if expected.nil?
      @rejected_credentials << [source_identity, credential]
      raise Tamoz::Stream::AuthenticationError.new(
        :forged_identity, "unknown source identity #{source_identity}"
      )
    end
    unless expected == credential
      @rejected_credentials << [source_identity, credential]
      raise Tamoz::Stream::AuthenticationError.new(
        :wrong_key, "credential does not match source identity #{source_identity}"
      )
    end
    @accepted_credentials << [source_identity, credential]
    SimulatedSourceSession.new
  end

  # A credential is replayed when the exact (identity, credential) pair was
  # already accepted. The connector rejects it durably.
  def authenticate_once(source_identity, credential)
    if @accepted_credentials.include?([source_identity, credential])
      @rejected_credentials << [source_identity, credential]
      raise Tamoz::Stream::AuthenticationError.new(
        :replayed_credential, "credential was already consumed for #{source_identity}"
      )
    end
    authenticate(source_identity, credential)
  end
end

class SimulatedSourceSession
  include Tamoz::Stream::SourceSession

  def initialize(events: [])
    @events = events.dup.freeze
    @index = 0
    @acked = []
  end

  def read
    event = @events[@index]
    @index += 1 if event
    event
  end

  def ack(event_id)
    @acked << event_id
  end

  def acked? = @acked.include?(events_first_id)

  def events_first_id
    @events.first&.event_id
  end
end
