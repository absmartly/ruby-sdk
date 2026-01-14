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

  ##
  # Fetches the UID for a named unit type.
  # @param [String, Symbol] unit_type - The unit type key; converted to a symbol for lookup.
  # @return [Object, nil] The UID stored for the given unit type, or nil if none exists.
  def unit(unit_type)
    @units[unit_type.to_sym]
  end

  ##
  # Merge the given attributes into the config's attributes, converting keys to symbols.
  # @param [Hash] attributes - Mapping of attribute names to values; keys will be converted to symbols before being merged.
  # @return [ContextConfig] self for method chaining.
  def set_attributes(attributes)
    @attributes.merge!(attributes.transform_keys(&:to_sym))
    self
  end

  ##
  # Set a single attribute on the context.
  # The attribute key is converted to a symbol before storing.
  # @param [String, Symbol] name - The attribute name.
  # @param [Object] value - The attribute value.
  # @return [ContextConfig] self, allowing method chaining.
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
end