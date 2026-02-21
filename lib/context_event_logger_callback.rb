# frozen_string_literal: true

class ContextEventLoggerCallback < ContextEventLogger
  attr_accessor :callable

  def initialize(callable)
    @callable = callable
  end

  def handle_event(event, data)
    @callable.call(event, data) if @callable && !@callable.nil?
  end
end
