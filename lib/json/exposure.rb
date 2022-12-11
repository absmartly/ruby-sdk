# frozen_string_literal: true

class Exposure
  attr_accessor :id, :name, :unit, :variant, :exposed_at, :assigned, :eligible,
                :overridden, :full_on, :custom, :audience_mismatch

  def initialize(id = nil, name = nil, unit = nil, variant = nil,
                 exposed_at = nil, assigned = nil, eligible = nil,
                 overridden = nil, full_on = nil, custom = nil,
                 audience_mismatch = nil)
    @id = id || 0
    @name = name
    @unit = unit
    @variant = variant
    @exposed_at = exposed_at
    @assigned = assigned
    @eligible = eligible
    @overridden = overridden
    @full_on = full_on
    @custom = custom
    @audience_mismatch = audience_mismatch
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    @id == o.id && @name == o.name && @unit == o.unit &&
      @variant == o.variant && @exposed_at == o.exposed_at &&
      @assigned == o.assigned && @eligible == o.eligible &&
      @overridden == o.overridden && @full_on == o.full_on &&
      @custom == o.custom && @audience_mismatch == o.audience_mismatch
  end

  def hash_code
    {
      id: @id, name: @name, unit: @unit,
      variant: @variant, exposed_at: @exposed_at,
      assigned: @assigned, eligible: @eligible,
      overridden: @overridden, full_on: @full_on,
      custom: @custom, audience_mismatch: @audience_mismatch
    }
  end

  def to_s
    "Exposure{" +
      "id=" + @id +
      "name='" + @name + "'" +
      ", unit=" + @unit +
      ", variant=" + @variant +
      ", exposed_at=" + @exposed_at +
      ", assigned=" + @assigned +
      ", eligible=" + @eligible +
      ", overridden=" + @overridden +
      ", full_on=" + @full_on +
      ", custom=" + @custom +
      ", audience_mismatch=" + @audience_mismatch +
      "}"
  end
end
