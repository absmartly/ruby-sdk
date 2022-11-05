# frozen_string_literal: true

require_relative "context_event_serializer"

class DefaultContextEventSerializer < ContextEventSerializer
  def serialize(event)
    event.to_json
  rescue StandardError
    nil
  end
end
