# frozen_string_literal: true

require_relative "binary_operator"

class VarOperator
  include BinaryOperator

  def evaluate(evaluator, path)
    if path.is_a?(Hash)
      path = to_sym(path)
      path = path[:path]
    end

    path.is_a?(String) ? evaluator.extract_var(path) : nil
  end

  private
    def to_sym(path)
      path.transform_keys(&:to_sym)
    end
end
