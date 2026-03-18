# frozen_string_literal: true

require_relative "default_context_publisher"

# @deprecated Use DefaultContextPublisher instead.
class DefaultContextEventHandler < DefaultContextPublisher
  def initialize(client)
    warn "[DEPRECATION] DefaultContextEventHandler is deprecated. Use DefaultContextPublisher instead."
    super(client)
  end
end
