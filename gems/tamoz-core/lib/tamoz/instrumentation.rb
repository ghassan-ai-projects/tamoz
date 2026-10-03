# frozen_string_literal: true

module Tamoz
  module Instrumentation
    MAX_EVENT_NAME_BYTES = 128
    MAX_SIGNAL_STRING_BYTES = 4_096
    EVENT_NAME_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/

    module_function

    def instrument(name, payload = {}, context:, &application)
      event_name = normalize_name(name)
      notifier = context&.notifier

      unless notifier&.respond_to?(:instrument)
        return application.call if application

        return false
      end

      safe_payload = Immutable.copy(payload, max_string_bytes: MAX_SIGNAL_STRING_BYTES)

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
      run = { executed: false, result: nil, error: nil }
      instrument_guarded(notifier, name, payload, run, &guard_application(application, run))
      raise run[:error] if run[:error]

      run[:executed] ? run[:result] : application.call
    end
    private_class_method :notify_with_guarded_block

    def guard_application(application, run)
      proc do
        raise ConfigurationError, "notifier attempted to execute the block more than once" if run[:executed]

        run[:executed] = true
        run[:result] = call_recording_error(application, run)
      end
    end
    private_class_method :guard_application

    def call_recording_error(application, run)
      application.call
    rescue Exception => error # rubocop:disable Lint/RescueException
      run[:error] = error
      raise
    end
    private_class_method :call_recording_error

    def instrument_guarded(notifier, name, payload, run, &)
      notifier.instrument(name, payload, &)
    rescue Exception => notifier_error # rubocop:disable Lint/RescueException
      raise run[:error] if run[:error]
      raise notifier_error unless notifier_error.is_a?(StandardError)
    end
    private_class_method :instrument_guarded

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
