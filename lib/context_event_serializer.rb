# frozen_string_literal: true

class ContextEventSerializer
  # @interface method
  def serialize(publish_event)
    raise NotImplementedError.new("You must implement serialize method.")
  end
end
