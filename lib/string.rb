# frozen_string_literal: true

class String
  def compare_to(another_string)
    value = self.bytes
    other = another_string.bytes
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

  def get_char(val, index)
    val[index] & 0xff
  end

  def underscore
    self.gsub(/::/, "/").
      gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').
      gsub(/([a-z\d])([A-Z])/, '\1_\2').
      tr("-", "_").
      downcase
  end
end
