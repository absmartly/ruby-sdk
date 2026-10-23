# frozen_string_literal: true

class ContextEventLogger
  module EVENT_TYPE
    ERROR = "error"
    READY = "ready"
    REFRESH = "refresh"
    PUBLISH = "publish"
    EXPOSURE = "exposure"
    GOAL = "goal"
    FINALIZE = "finalize"
    # Deprecated: the event is named "finalize" in every ABsmartly SDK.
    CLOSE = FINALIZE
  end

  def handle_event(event, data)
    raise NotImplementedError.new("You must implement handle_event method.")
  end
end
