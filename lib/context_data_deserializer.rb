# frozen_string_literal: true

class ContextDataDeserializer
  # @interface method
  def serialize(event)
    raise NotImplementedError.new("You must implement deserialize method.")
  end
end
