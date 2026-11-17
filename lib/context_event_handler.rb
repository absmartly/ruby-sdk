# frozen_string_literal: true

class ContextEventHandler
  # @interface method
  def publish(context, event)
    raise NotImplementedError.new("You must implement publish method.")
  end
end
