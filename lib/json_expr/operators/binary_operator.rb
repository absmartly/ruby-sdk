# frozen_string_literal: true

module BinaryOperator
  def evaluate(evaluator, args)
    if args.is_a? Array
      args_list = args
      lhs = args_list.size > 0 ? evaluator.evaluate(args_list[0]) : nil
      unless lhs.nil?
        rhs = args_list.size > 1 ? evaluator.evaluate(args_list[1]) : nil
        unless rhs.nil?
          return binary(evaluator, lhs, rhs)
        end
      end
    end
    nil
  end

  # @abstract method
  def binary(evaluator, lhs, rhs)
    raise NotImplementedError.new("You must implement binary method.")
  end
end
