# frozen_string_literal: true

require_relative "../string"
require_relative "experiment_application"
require_relative "experiment_variant"
require_relative "custom_field_value"

class Experiment
  attr_accessor :id, :name, :unit_type, :iteration, :seed_hi, :seed_lo, :split,
                :traffic_seed_hi, :traffic_seed_lo, :traffic_split, :full_on_variant,
                :applications, :variants, :audience_strict, :audience, :custom_field_values

  def initialize(args = {})
    args.each do |name, value|
      if name == :applications
        @applications = assign_to_klass(ExperimentApplication, value)
      elsif name == :variants
        @variants = assign_to_klass(ExperimentVariant, value)
      elsif name == :customFieldValues
        if value != nil
          @custom_field_values = assign_to_klass(CustomFieldValue, value)
        end
      else
        self.instance_variable_set("@#{name.to_s.underscore}", value)
      end
    end
    @audience_strict ||= false
    self
  end

  def assign_to_klass(klass, arr)
    arr.map do |item|
      return item if item.is_a?(klass)

      klass.new(*item.values)
    end
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    that = o
    @id == that.id && @iteration == that.iteration && @seed_hi == that.seed_hi && @seed_lo == that.seed_lo &&
      @traffic_seed_hi == that.traffic_seed_hi && @traffic_seed_lo == that.traffic_seed_lo &&
      @full_on_variant == that.full_on_variant && @name == that.name &&
      @unit_type == that.unit_type && @split == that.split &&
      @traffic_split == that.traffic_split && @applications == that.applications &&
      @variants == that.variants && @audience_strict == that.audience_strict &&
      @audience == that.audience && @custom_field_values == that.custom_field_values
  end

  def hash_code
    {
      id: @id,
      name: @name,
      unit_type: @unit_type,
      iteration: @iteration,
      seed_hi: @seed_hi,
      seed_lo: @seed_lo,
      traffic_seed_hi: @traffic_seed_hi,
      traffic_seed_lo: @traffic_seed_lo,
      full_on_variant: @full_on_variant,
      audience_strict: @audience_strict,
      audience: @audience,
      custom_field_values: @custom_field_values
    }
  end

  def to_s
    "ContextExperiment{" +
      "id= #{@id}"+
      ", name='#{@name}'" +
      ", unitType='#{@unit_type}'" +
      ", iteration=#{@iteration}" +
      ", seedHi=#{@seed_hi}" +
      ", seedLo=#{@seed_lo}" +
      ", split=#{@split.join}" +
      ", trafficSeedHi=#{@traffic_seed_hi}" +
      ", trafficSeedLo=#{@traffic_seed_lo}" +
      ", trafficSplit=#{@traffic_split.join}" +
      ", fullOnVariant=#{@full_on_variant}" +
      ", applications=#{@applications.join}" +
      ", variants=#{@variants.join}" +
      ", audienceStrict=#{@audience_strict}" +
      ", audience='#{@audience}'" +
      ", custom_field_values='#{@custom_field_values}'" +
      "}"
  end
end
