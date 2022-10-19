# frozen_string_literal: true

require_relative "./unary_operator"

class NilOperator
  include UnaryOperator

  def unary(evaluator, arg)
    arg.nil?
  end
end
