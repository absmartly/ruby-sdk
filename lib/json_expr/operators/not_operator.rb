# frozen_string_literal: true

require_relative "./unary_operator"

class NotOperator
  include UnaryOperator

  def unary(evaluator, args)
    !evaluator.boolean_convert(args)
  end
end
