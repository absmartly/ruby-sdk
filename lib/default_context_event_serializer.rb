# frozen_string_literal: true

require_relative "context_event_serializer"

class DefaultContextEventSerializer < ContextEventSerializer
  def serialize(event)
    req = {
      publishedAt: event.published_at,
      units: event.units.map do |unit|
        {
          type: unit.type,
          uid: unit.uid,
        }
      end,
      hashed: event.hashed
    }

    req[:goals] = event.goals.map do |x|
      {
        name: x.name,
        achievedAt: x.achieved_at,
        properties: x.properties,
      }
    end unless event.goals.nil?

    req[:exposures] = event.exposures.select { |x| !x.id.nil? }.map do |x|
      {
        id: x.id,
        name: x.name,
        unit: x.unit,
        exposedAt: x.exposed_at.to_i,
        variant: x.variant,
        assigned: x.assigned,
        eligible: x.eligible,
        overridden: x.overridden,
        fullOn: x.full_on,
        custom: x.custom,
        audienceMismatch: x.audience_mismatch
      }
    end unless event.exposures.nil?

    req[:attributes] = event.attributes.map do |x|
      {
        name: x.name,
        value: x.value,
        setAt: x.set_at,
      }
    end unless event.attributes.nil?

    req.to_json
  end
end
