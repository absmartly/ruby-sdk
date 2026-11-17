# frozen_string_literal: true

require_relative "binary_operator"
require_relative "../semver_comparator"

module Absmartly
  module SemverOperator
    include BinaryOperator

    def binary(evaluator, lhs, rhs)
      result = Absmartly::SemverComparator.compare(evaluator, lhs, rhs)
      return nil if result.nil?

      compare_result(result)
    end
  end
end
