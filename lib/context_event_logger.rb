# frozen_string_literal: true

class ContextEventLogger
  module EVENT_TYPE
    ERROR = "error"
    READY = "ready"
    REFRESH = "refresh"
    PUBLISH = "publish"
    EXPOSURE = "exposure"
    GOAL = "goal"
    # Logged by Context#close, as in v1.3.0.
    CLOSE = "close"
    # Logged by Context#finalize, the name the other ABsmartly SDKs use.
    FINALIZE = "finalize"
  end

  def handle_event(event, data)
    raise NotImplementedError.new("You must implement handle_event method.")
  end
end
