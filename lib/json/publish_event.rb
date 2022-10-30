# frozen_string_literal: true

class PublishEvent
  attr_accessor :hashed, :units, :published_at, :exposures, :goals, :attributes

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    that = o
    @hashed == that.hashed && @units == that.units &&
      @published_at == that.published_at && @exposures == that.exposures &&
      @goals == that.goals && @attributes == that.attributes
  end

  def hash_code
    {
      hashed: @hashed,
      units: @units,
      published_at: @published_at,
      exposures: @exposures,
      goals: @goals,
      attributes: @attributes
    }
  end

  def to_s
    "PublishEvent{" +
      "hashedUnits=" + @hashed +
      ", units=" + @units.join +
      ", publishedAt=" + @published_at +
      ", exposures=" + @exposures.join +
      ", goals=" + @goals.join +
      ", attributes=" + @attributes.join +
      "}"
  end
end
