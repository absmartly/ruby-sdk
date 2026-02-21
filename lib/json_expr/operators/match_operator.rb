# frozen_string_literal: true

require "timeout"
require_relative "binary_operator"

class MatchOperator
  include BinaryOperator
  MAX_PATTERN_LENGTH = 1000
  MATCH_TIMEOUT = 0.1

  def binary(evaluator, lhs, rhs)
    text = evaluator.string_convert(lhs)
    return nil if text.nil?

    pattern = evaluator.string_convert(rhs)
    return nil if pattern.nil?

    if pattern.length > MAX_PATTERN_LENGTH
      warn("Regex pattern too long (>#{MAX_PATTERN_LENGTH} chars), skipping match")
      return nil
    end

    begin
      Timeout.timeout(MATCH_TIMEOUT) do
        Regexp.new(pattern).match(text)
      end
    rescue Timeout::Error
      warn("Regex match timeout: pattern=#{pattern[0..50].inspect}...")
      nil
    rescue RegexpError => e
      warn("Invalid regex from server: #{e.message}")
      nil
    end
  end
end
