# frozen_string_literal: true

module TypeUtils
  def self.boolean?(value)
    case value
    when String then %w[true false].include?(value)
    when Array then false
    else false
    end
  end

  def self.compare_strings(str1, str2)
    value = str1.bytes
    other = str2.bytes
    len1 = value.size
    len2 = other.size
    lim = [len1, len2].min

    0.upto(lim - 1) do |k|
      if value[k] != other[k]
        return get_char(value, k) - get_char(other, k)
      end
    end
    len1 - len2
  end

  def self.get_char(val, index)
    val[index] & 0xff
  end

  def self.underscore(str)
    str.gsub(/::/, "/")
       .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
       .gsub(/([a-z\d])([A-Z])/, '\1_\2')
       .tr("-", "_")
       .downcase
  end

  def self.wrap_array(object)
    if object.nil?
      []
    elsif object.respond_to?(:to_ary)
      object.to_ary || [object]
    else
      [object]
    end
  end
end
