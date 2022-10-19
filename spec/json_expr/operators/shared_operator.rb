# frozen_string_literal: true

require "json_expr/evaluator"

RSpec.shared_examples "shared operator" do
  before(:each) do
    reset_evaluator
  end

  attr_reader :evaluator

  def reset_evaluator
    @evaluator = Evaluator.new

    allow(@evaluator).to receive(:evaluate).and_wrap_original do |_, *invocation|
      invocation[0]
    end

    allow(@evaluator).to receive(:boolean_convert).and_wrap_original do |_, *invocation|
      arg = invocation[0]
      arg.nil? ? false : arg
    end

    allow(@evaluator).to receive(:string_convert).and_wrap_original do |_, *invocation|
      invocation[0].to_s
    end

    allow(@evaluator).to receive(:number_convert).and_wrap_original do |_, *invocation|
      invocation[0]
    end

    allow(@evaluator).to receive(:extract_var).and_wrap_original do |_, *invocation|
      "abc" if invocation[0] == "a/b/c"
    end

    allow(@evaluator).to receive(:compare).and_wrap_original do |_, *invocation|
      lhs = invocation[0]
      rhs = invocation[1]

      if lhs.is_a?(TrueClass) || lhs.is_a?(FalseClass)
        lhs <=> rhs
      elsif lhs.is_a?(Numeric)
        lhs.to_s.casecmp(rhs.to_s)
      elsif lhs.is_a?(String)
        lhs.compare_to(rhs)
      elsif lhs == rhs
        0
      else
        nil
      end
    end
    @evaluator
  end
end
