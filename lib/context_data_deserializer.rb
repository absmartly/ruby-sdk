# frozen_string_literal: true

class ContextDataDeserializer
  # @interface method
  def deserialize(bytes, offset, length)
    raise NotImplementedError.new("You must implement deserialize method.")
  end
end
