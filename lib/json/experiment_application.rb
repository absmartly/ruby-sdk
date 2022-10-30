# frozen_string_literal: true

class ExperimentApplication
  attr_accessor :name

  def initialize(name = nil)
    @name = name
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    that = o
    @name == that.name
  end

  def hash_code
    { name: @name }
  end

  def to_s
    "ExperimentApplication{" +
      "name='" + @name + "'" +
      "}"
  end
end
