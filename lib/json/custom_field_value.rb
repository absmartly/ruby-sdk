# frozen_string_literal: true

class CustomFieldValue
  attr_accessor :name, :type, :value

  def initialize(name, value, type)
    @name = name
    @type = type
    @value = value
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    that = o
    @name == that.name && @type == that.type  && @value == that.value
  end

  def hash_code
    { name: @name, type: @type, value: @value }
  end

  def to_s
    "CustomFieldValue{" +
      "name='#{@name}'" +
      ", type='#{@type}'" +
      ", value='#{@value}'" +
      "}"
  end
end
