# frozen_string_literal: true

class ContextEventHandler
  # @interface method
  def publish
    raise NotImplementedError.new("You must implement publish method.")
  end
end
