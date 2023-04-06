# frozen_string_literal: true

class ContextEventLogger
  module EVENT_TYPE
    ERROR = "error"
    READY = "ready"
    REFRESH = "refresh"
    PUBLISH = "publish"
    EXPOSURE = "exposure"
    GOAL = "goal"
    CLOSE = "close"
  end

  def handle_event(event, data)
    raise NotImplementedError.new("You must implement handle_event method.")
  end
end
