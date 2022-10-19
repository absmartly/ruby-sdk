# frozen_string_literal: true

class ContextDataProvider
  # @interface method
  def context_data
    raise NotImplementedError.new("You must implement context_data method.")
  end
end
