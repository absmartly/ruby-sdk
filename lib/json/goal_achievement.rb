# frozen_string_literal: true

class GoalAchievement
  attr_accessor :name, :achieved_at, :properties

  def initialize(name = nil, achieved_at = nil, properties = nil)
    @name = name
    @achieved_at = achieved_at
    @properties = properties
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    that = o
    @name == that.name && @achieved_at == that.achieved_at &&
      @properties == that.properties
  end

  def hash_code
    { name: @name, achieved_at: @achieved_at, properties: @properties }
  end

  def to_s
    "GoalAchievement{" +
      "name='#{@name}'" +
      ", achieved_at='#{@achieved_at}'" +
      ", properties='#{@properties.inspect}'" +
      "}"
  end
end
