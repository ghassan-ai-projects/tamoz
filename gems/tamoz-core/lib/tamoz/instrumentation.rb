# frozen_string_literal: true

module Tamoz
  module Instrumentation
    MAX_EVENT_NAME_BYTES = 128
    EVENT_NAME_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/

    module_function

    def instrument(name, payload = {}, context:, &application)
      event_name = normalize_name(name)
      safe_payload = Immutable.copy(payload)
      notifier = context&.notifier

      unless notifier&.respond_to?(:instrument)
        return application.call if application

        return false
      end

      return notify_without_block(notifier, event_name, safe_payload) unless application

      notify_with_guarded_block(notifier, event_name, safe_payload, application)
    end

    def notify_without_block(notifier, name, payload)
      notifier.instrument(name, payload)
      true
    rescue StandardError
      false
    end
    private_class_method :notify_without_block

    def notify_with_guarded_block(notifier, name, payload, application)
      executed = false
      result = nil
      application_error = nil

      guarded = proc do
        raise ConfigurationError, "notifier attempted to execute the block more than once" if executed

        executed = true
        begin
          result = application.call
        rescue Exception => error # rubocop:disable Lint/RescueException
          application_error = error
          raise
        end
      end

      begin
        notifier.instrument(name, payload, &guarded)
      rescue Exception => notifier_error # rubocop:disable Lint/RescueException
        raise application_error if application_error
        raise notifier_error unless notifier_error.is_a?(StandardError)
      end

      raise application_error if application_error
      result = application.call unless executed
      result
    end
    private_class_method :notify_with_guarded_block

    def normalize_name(name)
      SafeText.normalize(
        name,
        name: "instrumentation name",
        max_bytes: MAX_EVENT_NAME_BYTES,
        error_class: ArgumentError,
        pattern: EVENT_NAME_PATTERN
      )
    end
    private_class_method :normalize_name
  end

  def self.instrument(name, payload = {}, context:, &block)
    Instrumentation.instrument(name, payload, context:, &block)
  end

  private_constant :Instrumentation
end
