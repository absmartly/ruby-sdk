# frozen_string_literal: true

class Attribute
  attr_accessor :name, :value, :set_at

  def initialize(name = nil, value = nil, set_at = nil)
    @name = name
    @value = value
    @set_at = set_at
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    @name == o.name && @value == o.value && @set_at == o.set_at
  end

  def hash_code
    { name: @name, value: @value, set_at: @set_at }
  end

  def to_s
    "Attribute{" +
      "name='" + @name + "'" +
      ", value=" + @value +
      ", setAt=" + @set_at +
      "}"
  end
end
