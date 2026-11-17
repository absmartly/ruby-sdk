# frozen_string_literal: true

require_relative "experiment"

class ContextData
  attr_accessor :experiments, :holdouts

  # Holdouts decode with the Experiment model. @holdouts is only set when the
  # payload has a holdouts array, so a payload without one builds the same
  # object as before. An entry that can't be decoded is dropped on its own.
  def initialize(experiments = [], holdouts = nil)
    @experiments = experiments.map do |experiment|
      Experiment.new(experiment)
    end unless experiments.nil?
    @holdouts = holdouts.filter_map { |holdout| decode_holdout(holdout) } if holdouts.is_a?(Array)
    self
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    @experiments == o.experiments && holdouts == o.holdouts
  end

  def hash_code
    { name: @name, config: @config }
  end

  def to_s
    "ContextData{" +
      "experiments='" + @experiments.join +
      "}"
  end

  private
    # A holdout only needs its id, iteration, seeds and split, so nested fields
    # that can't be decoded are dropped rather than the whole holdout.
    def decode_holdout(holdout)
      return holdout if holdout.is_a?(Experiment)
      return nil unless holdout.is_a?(Hash)

      begin
        Experiment.new(holdout)
      rescue StandardError
        Experiment.new(holdout.reject { |key, _| NESTED_HOLDOUT_KEYS.include?(key.to_s) })
      end
    rescue StandardError
      nil
    end

    NESTED_HOLDOUT_KEYS = %w[applications variants customFieldValues custom_field_values].freeze
    private_constant :NESTED_HOLDOUT_KEYS
end
