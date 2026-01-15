# frozen_string_literal: true

class ContextConfig
  attr_accessor :units, :attributes, :custom_assignments, :overrides,
                :event_logger, :publish_delay, :refresh_interval

  def self.create
    ContextConfig.new
  end

  def initialize
    @units = {}
    @attributes = {}
    @overrides = {}
    @custom_assignments = {}
  end

  def set_unit(unit_type, uid)
    @units[unit_type.to_sym] = uid
    self
  end

  def set_units(units)
    units.map { |k, v| set_unit(k, v) }
  end

  def unit(unit_type)
    @units[unit_type.to_sym]
  end

  def set_attributes(attributes)
    @attributes.merge!(attributes.transform_keys(&:to_sym))
    self
  end

  def set_attribute(name, value)
    @attributes[name.to_sym] = value
    self
  end

  def attribute(name)
    @attributes[name.to_sym]
  end

  def set_overrides(overrides)
    @overrides.merge!(overrides.transform_keys(&:to_sym))
  end

  def set_override(experiment_name, variant)
    @overrides[experiment_name.to_sym] = variant
    self
  end

  def override(experiment_name)
    @overrides[experiment_name.to_sym]
  end

  def set_custom_assignment(experiment_name, variant)
    @custom_assignments[experiment_name.to_sym] = variant
    self
  end

  def set_custom_assignments(customAssignments)
    @custom_assignments.merge!(customAssignments.transform_keys(&:to_sym))
    self
  end

  def custom_assignment(experiment_name)
    @custom_assignments[experiment_name.to_sym]
  end


  def set_event_logger(event_logger)
    @event_logger = event_logger
    self
  end

  attr_reader :event_logger
end
