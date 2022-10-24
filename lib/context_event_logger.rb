# frozen_string_literal: true

class ContextEventLogger
  EVENT_TYPE = %w[error ready refresh publish exposure goal close]
  # @interface method
  def handle_event
    raise NotImplementedError.new("You must implement handleEvent method.")
  end
end
