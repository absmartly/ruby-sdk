# frozen_string_literal: true

module Operator
  # @interface method
  def evaluate(evaluator, args)
    raise NotImplementedError.new("You must implement evaluate method.")
  end
end
