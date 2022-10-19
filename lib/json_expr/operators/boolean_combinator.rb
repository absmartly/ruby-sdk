# frozen_string_literal: true

module BooleanCombinator
  def evaluate(evaluator, args)
    if args.is_a? Array
      return combine(evaluator, args)
    end
    nil
  end

  # @abstract method
  def combine(evaluator, args)
    raise NotImplementedError.new("You must implement combine method.")
  end
end
