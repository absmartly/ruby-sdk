# frozen_string_literal: true

class ScheduledExecutorService
  # @interface method
  def schedule(command, delay, unit)
    raise NotImplementedError.new("You must implement schedule method.")
  end
end
