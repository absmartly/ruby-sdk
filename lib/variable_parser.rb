# frozen_string_literal: true

class VariableParser
  # @interface method
  def parse
    raise NotImplementedError.new("You must implement parse method.")
  end
end
