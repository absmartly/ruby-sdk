# frozen_string_literal: true

class Unit
  attr_accessor :type, :uid

  def initialize(type = nil, uid = nil)
    @type = type
    @uid = uid
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    @type == o.type && @uid == o.uid
  end

  def hash_code
    {
      type: @type, uid: @uid
    }
  end

  def to_s
    "Unit{" +
      "type='" + @type + "'" +
      ", uid=" + @uid +
      "}"
  end
end
