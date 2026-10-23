# frozen_string_literal: true

require_relative "../type_utils"
require_relative "./evaluator"
EMPTY_MAP = {}
EMPTY_LIST = []

class ExprEvaluator < Evaluator
  attr_accessor :operators
  attr_accessor :vars
  NUMERIC_REGEX = /\A[-+]?[0-9]*\.?[0-9]+\Z/

  def initialize(operators, vars)
    @operators = operators
    @vars = vars
  end

  def evaluate(expr)
    if expr.is_a? Array
      return @operators[:and].evaluate(self, expr)
    elsif expr.is_a? Hash
      expr.transform_keys(&:to_sym).each do |key, value|
        if @operators[key]
          return @operators[key].evaluate(self, value)
        end
      end
    end
    nil
  end

  def boolean_convert(x)
    if x.is_a?(TrueClass) || x.is_a?(FalseClass)
      return x
    elsif x.is_a?(Numeric) || !(x.to_s =~ NUMERIC_REGEX).nil?
      return !x.to_f.zero?
    elsif x.is_a?(String)
      return x != "false" && x != "0" && x != ""
    end

    !x.nil?
  end

  def number_convert(x)
    return if x.nil? || x.to_s.empty?

    if x.is_a?(Numeric) || !(x.to_s =~ NUMERIC_REGEX).nil?
      return x.to_f
    elsif x.is_a?(TrueClass) || x.is_a?(FalseClass)
      return x ? 1.0 : 0.0
    end
    nil
  end

  def string_convert(x)
    if x.is_a?(String)
      return x
    elsif x.is_a?(TrueClass) || x.is_a?(FalseClass)
      return x.to_s
    elsif x.is_a?(Numeric) || !(x.to_s =~ NUMERIC_REGEX).nil?
      return x == x.to_i ? x.to_i.to_s : x.to_s
    end
    nil
  end

  def extract_var(path)
    frags = path.split("/")
    target = !vars.nil? ? vars : {}

    frags.each do |frag|
      list = target
      value = nil
      if target.is_a?(Array)
        value = list[frag.to_i]
      elsif target.is_a?(Hash)
        value = list[frag].nil? ? list[frag.to_sym] : list[frag]
      end

      unless value.nil?
        target = value
        next
      end

      return nil
    end
    target
  end

  def compare(lhs, rhs)
    if lhs.nil?
      return rhs.nil? ? 0 : nil
    elsif rhs.nil?
      return nil
    end

    if lhs.is_a?(Numeric)
      rvalue = number_convert(rhs)
      return nil if rvalue.nil?
      return lhs.to_f <=> rvalue.to_f
    elsif lhs.is_a?(String)
      rvalue = string_convert(rhs)
      return TypeUtils.compare_strings(lhs, rvalue) unless rvalue.nil?
    elsif lhs.is_a?(TrueClass) || lhs.is_a?(FalseClass)
      rvalue = boolean_convert(rhs)
      return lhs.to_s.casecmp(rvalue.to_s) unless rvalue.nil?
    elsif lhs.class == rhs.class && lhs === rhs
      return 0
    end
    nil
  end
end
