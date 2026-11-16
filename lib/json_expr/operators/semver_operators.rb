# frozen_string_literal: true

require_relative "semver_operator"

class SemverEqualsOperator
  include SemverOperator

  private
    def compare_result(result)
      result.zero?
    end
end

class SemverGreaterThanOperator
  include SemverOperator

  private
    def compare_result(result)
      result.positive?
    end
end

class SemverGreaterThanOrEqualOperator
  include SemverOperator

  private
    def compare_result(result)
      result >= 0
    end
end

class SemverLessThanOperator
  include SemverOperator

  private
    def compare_result(result)
      result.negative?
    end
end

class SemverLessThanOrEqualOperator
  include SemverOperator

  private
    def compare_result(result)
      result <= 0
    end
end
