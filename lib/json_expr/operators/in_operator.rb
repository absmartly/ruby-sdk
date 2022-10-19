# frozen_string_literal: true

require_relative "binary_operator"

class InOperator
  include BinaryOperator

  def binary(evaluator, haystack, needle)
    if haystack.is_a? Array
      haystack.each do |item|
        return true if evaluator.compare(item, needle) == 0
      end
      return false
    elsif haystack.is_a? String
      needle_string = evaluator.string_convert(needle)
      return !needle_string.nil? && haystack.include?(needle_string)
    elsif haystack.is_a?(Hash)
      needle_string = evaluator.string_convert(needle)
      return !needle_string.nil? && haystack.key?(needle_string)
    end
    nil
  end
end
