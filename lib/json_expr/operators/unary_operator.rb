# frozen_string_literal: true

module UnaryOperator
  def evaluate(evaluator, args)
    arg = evaluator.evaluate(args)
    unary(evaluator, arg)
  end

  # @abstract method
  def unary(evaluator, arg)
    raise NotImplementedError.new("You must implement unnnary method.")
  end
end
