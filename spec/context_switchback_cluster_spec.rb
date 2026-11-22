# frozen_string_literal: true

require "switchback_support"

# Ports of java-sdk ContextSwitchbackClusterTest and ContextSwitchbackClusterRuleTest
# (core-api/src/test/java/com/absmartly/sdk). Variants come from the raw key and the assigner,
# both pinned by the platform golden vectors.
module ContextSwitchbackClusterSpec
  UNIT_TYPE = "store_id"
  UID = "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
  SEED_HI = -5
  SEED_LO = -7
  # An audience the context never matches (no "tier" attribute).
  STRICT_GOLD_AUDIENCE = '{"filter":[{"eq":[{"var":"tier"},{"value":"gold"}]}]}'
  HOUR = SwitchbackSpecSupport::HOUR
  ANCHOR = SwitchbackSpecSupport::ANCHOR

  RSpec.describe "Context switchback clusters" do
    include SwitchbackSpecSupport

    ARMS = 3

    let(:clock) { SwitchbackSpecSupport::MutableClock.new(ANCHOR) }
    let(:provider) { double("ContextDataProvider") }

    def attribute_switchback(path, **extra)
      {
        id: 1, name: "exp_sb", unitType: UNIT_TYPE, iteration: 1, seedHi: SEED_HI, seedLo: SEED_LO,
        split: Array.new(ARMS) { 1.0 / ARMS },
        variants: Array.new(ARMS) { |i| { name: ("A".ord + i).chr, config: "{\"sb.arm\":#{i}}" } },
        trafficSeedHi: 1, trafficSeedLo: 2, trafficSplit: [0.0, 1.0], fullOnVariant: 0,
        applications: [{ name: "website" }], audienceStrict: false, audience: nil,
        randomizationType: "switchback", switchbackClusters: { UNIT_TYPE => path },
        switchbackStartAt: ANCHOR, switchbackPeriodMs: HOUR, switchbackDesignType: "balanced_block"
      }.merge(extra)
    end

    def create_context(experiment, units: { UNIT_TYPE => UID })
      build_context(data_of([experiment]), units: units, provider: provider)
    end

    def refresh_to(context, experiment)
      allow(provider).to receive(:context_data).and_return(ready(data_of([experiment])))
      context.refresh
    end

    def expected(key, period)
      draw(key, period, SEED_HI, SEED_LO, ARMS)
    end

    def expected_schedule(key)
      (0...12).map { |i| expected(key, i) }
    end

    def peek_schedule(context)
      (0...12).map do |i|
        clock.now = ANCHOR + i * HOUR
        context.peek_treatment("exp_sb")
      end
    end

    def sb_exposure(variant, exposed_at, eligible, audience_mismatch)
      exposure(1, "exp_sb", UNIT_TYPE, variant, exposed_at, true, eligible, false, false, false, audience_mismatch)
    end

    # The Collector re-resolves the cluster from the published attributes at exposedAt, so an
    # exposure must point at an instant whose attributes give the cluster the SDK served.
    def collector_cluster(event, exposure, path)
      selected = event.attributes.select { |a| a.name.to_s.strip == path && a.set_at <= exposure.exposed_at }
                      .max_by.with_index { |a, i| [a.set_at, i] }
      selected&.value
    end

    def expose_and_publish(context)
      clock.now = ANCHOR
      context.treatment("exp_sb")
      context.publish
      context.send(:event_handler).events.last
    end

    it "never keys the cluster by the unit uid" do
      context = create_context(attribute_switchback("city"))
      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(0)
      end
      expect(context.pending_count).to eq(0)
    end

    # A numeric uid serves and publishes as its canonical text does; the key is the attribute.
    it "clusters a numeric unit uid like its canonical string" do
      [[123_456_789, "123456789"], [123_456_789.0, "123456789"], [125.75, "126"]].each do |uid, text|
        numeric = create_context(attribute_switchback("city"), units: { UNIT_TYPE => uid })
        clock.now = ANCHOR
        numeric.set_attribute("city", "Lisboa")
        numeric_event = expose_and_publish(numeric)
        numeric_schedule = peek_schedule(numeric)
        textual = create_context(attribute_switchback("city"), units: { UNIT_TYPE => text })
        clock.now = ANCHOR
        textual.set_attribute("city", "Lisboa")
        text_event = expose_and_publish(textual)

        expect(numeric_schedule).to eq(expected_schedule("Lisboa"))
        expect(numeric_schedule).to eq(peek_schedule(textual))
        expect(numeric_event.units).to eq(text_event.units)
        expect(numeric_event.exposures).to eq(text_event.exposures)
        expect(numeric_event.units[0].uid).to eq(Hashing.hash_unit(text))
      end
    end

    # Independent reference hashes, and the raw-key schedule of 123456789 as an Integer attribute.
    it "matches the independent reference for numeric uids and an integer cluster value" do
      schedule = [0, 2, 1, 0, 1, 2, 0, 1, 2, 2, 1, 0]
      [[123_456_789, "JfnnlDI7RTiF9RgfG2JNCw"], [9_007_199_254_740_993, "OngwCmjeKhIQyeNybDy4eg"]].each do |uid, hash|
        context = create_context(attribute_switchback("region"), units: { UNIT_TYPE => uid })
        clock.now = ANCHOR
        context.set_attribute("region", 123_456_789)
        event = expose_and_publish(context)

        # Integer uids hash from their exact decimal text, so 2**53 + 1 is its own unit here.
        expect(event.units[0].uid).to eq(uid == 123_456_789 ? hash : Hashing.hash_unit("9007199254740993"))
        expect(event.exposures).to eq([sb_exposure(schedule[0], ANCHOR, true, false)])
        expect(peek_schedule(context)).to eq(schedule)
      end
    end

    # Periods 0..11 of the raw key "Lisboa", from the independent murmur3 reference.
    it "serves the raw attribute value" do
      context = create_context(attribute_switchback("city"))
      context.set_attribute("city", "Lisboa")
      expect(peek_schedule(context)).to eq([0, 2, 1, 2, 1, 0, 1, 0, 2, 0, 1, 2])
      expect(peek_schedule(context)).to eq(expected_schedule("Lisboa"))
    end

    it "shares the schedule between units sharing an attribute value" do
      lisboa = create_context(attribute_switchback("city"))
      lisboa.set_attribute("city", "Lisboa")
      porto = create_context(attribute_switchback("city"))
      porto.set_attribute("city", "Porto")
      other = create_context(attribute_switchback("city"), units: { UNIT_TYPE => "another-store" })
      other.set_attribute("city", "Lisboa")

      expect(peek_schedule(lisboa)).to eq(expected_schedule("Lisboa"))
      expect(peek_schedule(other)).to eq(expected_schedule("Lisboa"))
      expect(peek_schedule(porto)).to eq(expected_schedule("Porto"))
      expect(expected_schedule("Lisboa")).not_to eq(expected_schedule("Porto"))
    end

    it "resolves nested and array paths and integer values" do
      nested = create_context(attribute_switchback("geo/city"))
      nested.set_attribute("geo", { "city" => "Porto" })
      expect(peek_schedule(nested)).to eq(expected_schedule("Porto"))

      clock.now = ANCHOR
      symbols = create_context(attribute_switchback("geo/city"))
      symbols.set_attribute(:geo, { city: :Porto })
      expect(peek_schedule(symbols)).to eq(expected_schedule("Porto"))

      clock.now = ANCHOR
      array = create_context(attribute_switchback("items/1/city"))
      array.set_attribute("items", [{ "city" => "Lisbon" }, { "city" => "Faro" }])
      expect(peek_schedule(array)).to eq(expected_schedule("Faro"))

      clock.now = ANCHOR
      integer = create_context(attribute_switchback("region"))
      integer.set_attribute("region", 42)
      expect(peek_schedule(integer)).to eq(expected_schedule("42"))

      # Read through the JSON encoding the Collector sees: a Symbol is a string.
      clock.now = ANCHOR
      symbol = create_context(attribute_switchback("city"))
      symbol.set_attribute("city", :c)
      expect(peek_schedule(symbol)).to eq(expected_schedule("c"))

      # A BigDecimal (a bundled gem, not in the Gemfile, from Ruby 3.4) is published as its JSON
      # text ("0.42e2"), which the Collector keys as a string.
      if SwitchbackSpecSupport.big_decimal?
        clock.now = ANCHOR
        decimal = create_context(attribute_switchback("geo/city"))
        decimal.set_attribute("geo", { "city" => BigDecimal("42") })
        expect(peek_schedule(decimal)).to eq(expected_schedule("0.42e2"))
      end

      clock.now = ANCHOR + 10
      floating = create_context(attribute_switchback("city"))
      floating.set_attribute("city", 2.0)
      expect(floating.treatment("exp_sb")).to eq(0)
      expect(floating.pending_count).to eq(0)
    end

    it "makes values without a cluster key ineligible" do
      [nil, "", true, false, 1.5, 2.0, 3.0, { "a" => "b" }, ["x"]].each do |value|
        clock.now = ANCHOR
        context = create_context(attribute_switchback("city"))
        context.set_attribute("city", value)
        clock.now = ANCHOR + 10
        expect(context.treatment("exp_sb")).to eq(0), value.inspect
        expect(context.variable_value("sb.arm", -1)).to eq(0), value.inspect
        expect(context.pending_count).to eq(0), value.inspect
      end

      missing = create_context(attribute_switchback("geo/city"))
      missing.set_attribute("geo", { "country" => "PT" })
      clock.now = ANCHOR + 10
      expect(missing.treatment("exp_sb")).to eq(0)
      expect(missing.pending_count).to eq(0)
    end

    # The Collector reads the published JSON text, so a UTF-16 string keys like its UTF-8 twin, for
    # the draw and the allow-list.
    it "keys a string by its published UTF-8 text" do
      [nil, ["Zürich"]].each do |allowed|
        utf8 = create_context(attribute_switchback("city", switchbackClusterValues: allowed))
        utf8.set_attribute("city", "Zürich")
        utf16 = create_context(attribute_switchback("city", switchbackClusterValues: allowed))
        utf16.set_attribute("city", "Zürich".encode("UTF-16LE"))
        clock.now = ANCHOR + 10
        expect(utf16.treatment("exp_sb")).to eq(expected("Zürich", 0)), allowed.inspect
        expect(utf8.treatment("exp_sb")).to eq(expected("Zürich", 0))
        expect(published_exposures(utf16)).to eq(published_exposures(utf8))
        expect(utf8.pending_count).to eq(0)
      end
      expect(expected("Zürich", 0)).not_to eq(0)

      binary = create_context(attribute_switchback("city"))
      binary.set_attribute("city", "Zürich".b)
      expect(binary.treatment("exp_sb")).to eq(expected("Zürich", 0))

      invalid = create_context(attribute_switchback("city"))
      invalid.set_attribute("city", "\xFF".b)
      expect(invalid.treatment("exp_sb")).to eq(0)
      expect(invalid.pending_count).to eq(0)
    end

    it "makes values without a JSON encoding ineligible" do
      cyclic = {}
      cyclic["self"] = cyclic
      [cyclic, [Float::NAN], { "city" => Float::INFINITY }].each do |value|
        context = create_context(attribute_switchback("geo/city"))
        context.set_attribute("geo", value)
        expect(context.treatment("exp_sb")).to eq(0)
        expect(context.pending_count).to eq(0)
      end
    end

    it "makes unservable configurations ineligible" do
      experiments = ["items/0", "items/-1/city", "", "geo.city", "'city", "\"city", nil, 7].map do |path|
        attribute_switchback("city", switchbackClusters: { UNIT_TYPE => path })
      end
      experiments << attribute_switchback("city", switchbackPeriodMs: nil)
      experiments << attribute_switchback("city", switchbackPeriodMs: 0)
      experiments << attribute_switchback("city", switchbackPeriodMs: -HOUR)
      experiments << attribute_switchback("city", switchbackPeriodMs: 1.5 * HOUR)
      experiments << attribute_switchback("city", split: [1.0], variants: [{ name: "A", config: nil }])
      experiments << attribute_switchback("city", switchbackClusters: "store_id")
      experiments << attribute_switchback("city", switchbackClusters: [[UNIT_TYPE, "city"]])
      experiments.each do |experiment|
        clock.now = ANCHOR
        context = create_context(experiment)
        context.set_attribute("city", "Lisboa")
        context.set_attribute("items", [{ "city" => "Lisbon" }])
        3.times do |i|
          clock.now = ANCHOR + i * HOUR
          expect(context.treatment("exp_sb")).to eq(0), experiment.inspect
        end
        expect(context.pending_count).to eq(0), experiment.inspect
      end
    end

    # The legacy path: a unit of the declared unitType only identifies an ineligible control;
    # without one the experiment does not apply.
    it "makes a missing or empty cluster map only a legacy ineligible control" do
      [nil, {}].each do |clusters|
        context = create_context(attribute_switchback("city", switchbackClusters: clusters))
        context.set_attribute("city", "Lisboa")
        expect(context.treatment("exp_sb")).to eq(0)
        expect(context.variable_value("sb.arm", -1)).to eq(0)
        expect(context.pending_count).to eq(0)

        other = create_context(attribute_switchback("city", switchbackClusters: clusters), units: { "user_id" => "u1" })
        other.set_attribute("city", "Lisboa")
        expect(other.treatment("exp_sb")).to eq(0)
        expect(other.variable_value("sb.arm", -1)).to eq(-1)
        expect(other.pending_count).to eq(0)
      end
    end

    it "uses the latest attribute set at or before the resolution instant" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 2 * HOUR
      context.set_attribute("city", "Porto")
      clock.now = ANCHOR + 4 * HOUR
      context.set_attribute("city", "Lisboa")

      clock.now = ANCHOR + HOUR
      expect(context.peek_treatment("exp_sb")).to eq(0)
      clock.now = ANCHOR + 3 * HOUR
      expect(context.peek_treatment("exp_sb")).to eq(expected("Porto", 3))
      clock.now = ANCHOR + 4 * HOUR
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 4))
    end

    # Lisboa and Faro draw different variants in period 0, so the winner is visible.
    it "breaks a setAt tie with the attribute set last" do
      expect(expected("Lisboa", 0)).not_to eq(expected("Faro", 0))
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 5
      context.set_attribute("city", "Faro")
      context.set_attribute("city", "Lisboa")
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))

      other = create_context(attribute_switchback("city"))
      other.set_attribute("city", "Lisboa")
      other.set_attribute("city", "Faro")
      expect(other.peek_treatment("exp_sb")).to eq(expected("Faro", 0))
    end

    it "matches attribute names with surrounding spaces trimmed" do
      context = create_context(attribute_switchback("city"))
      context.set_attribute(" city ", "Faro")
      expect(context.peek_treatment("exp_sb")).to eq(expected("Faro", 0))
    end

    it "never reads the application or environment system attributes" do
      context = create_context(attribute_switchback("environment"))
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(0)
    end

    it "does not reassign within the period after a mid-period setAttribute" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      clock.now = ANCHOR + 20
      context.set_attribute("city", "Porto")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      expect(context.pending_count).to eq(1)

      differing = 0
      (1...12).each do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(expected("Porto", i))
        differing += 1 if expected("Porto", i) != expected("Lisboa", i)
      end
      expect(differing).not_to eq(0)
      expect(context.pending_count).to eq(12)
    end

    it "waits for the next period after an ineligible resolution" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(0)
      context.set_attribute("city", "Lisboa")
      clock.now = ANCHOR + 20
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(0)

      clock.now = ANCHOR + HOUR
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 1))
      expect(published_exposures(context)).to eq([sb_exposure(expected("Lisboa", 1), ANCHOR + HOUR, true, false)])
    end

    it "keeps the period's key across traffic changes within the period" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      clock.now = ANCHOR + 20
      context.set_attribute("city", "Porto")
      refresh_to(context, attribute_switchback("city", trafficSplit: [1.0, 0.0]))
      expect(context.treatment("exp_sb")).to eq(0)

      refresh_to(context, attribute_switchback("city"))
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      expect(context.pending_count).to eq(3)

      clock.now = ANCHOR + HOUR
      expect(context.treatment("exp_sb")).to eq(expected("Porto", 1))
    end

    # The cluster is resolved before traffic: a miss is recorded, and traffic restored later in
    # the period serves the key read first.
    it "keeps the key when traffic is restored within the period" do
      context = create_context(attribute_switchback("city", trafficSplit: [1.0, 0.0]))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Faro")
      expect(context.treatment("exp_sb")).to eq(0)

      clock.now = ANCHOR + 20
      context.set_attribute("city", "Lisboa")
      refresh_to(context, attribute_switchback("city"))
      expect(expected("Faro", 0)).to eq(1)
      expect(context.treatment("exp_sb")).to eq(expected("Faro", 0))
      # The second exposure keeps the Faro key: at ANCHOR + 20 the batch's city is Lisboa, so it is
      # published in a body of its own with the attributes its slot read, at its own instant.
      expect(published_exposures(context)).to eq([sb_exposure(0, ANCHOR + 10, false, false),
                                                  sb_exposure(expected("Faro", 0), ANCHOR + 20, true, false)])
      separate = context.send(:event_handler).events.last
      expect(collector_cluster(separate, separate.exposures[0], "city")).to eq("Faro")
    end

    # An audience change re-resolves the slot (a new exposure) but keeps its key.
    it "keeps the period's key when the audience is re-evaluated" do
      context = create_context(attribute_switchback("city", audience: STRICT_GOLD_AUDIENCE))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.set_attribute("tier", "gold")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      clock.now = ANCHOR + 20
      context.set_attribute("city", "Porto")
      context.set_attribute("tier", "silver")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      # At ANCHOR + 20 the batch's city is Porto, so the second exposure goes in its own body.
      expect(published_exposures(context)).to eq([sb_exposure(expected("Lisboa", 0), ANCHOR + 10, true, false),
                                                  sb_exposure(expected("Lisboa", 0), ANCHOR + 20, true, true)])
      separate = context.send(:event_handler).events.last
      expect(collector_cluster(separate, separate.exposures[0], "city")).to eq("Lisboa")
    end

    it "keeps a missing key through an audience re-evaluation" do
      context = create_context(attribute_switchback("city", audience: STRICT_GOLD_AUDIENCE))
      clock.now = ANCHOR + 10
      context.set_attribute("tier", "gold")
      expect(context.treatment("exp_sb")).to eq(0)

      clock.now = ANCHOR + 20
      context.set_attribute("city", "Faro")
      context.set_attribute("tier", "silver")
      expect(expected("Faro", 0)).to eq(1)
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(0)

      clock.now = ANCHOR + HOUR
      expect(context.peek_treatment("exp_sb")).to eq(expected("Faro", 1))
      clock.now = ANCHOR + 2 * HOUR
      expect(expected("Faro", 2)).to eq(2)
      expect(context.peek_treatment("exp_sb")).to eq(expected("Faro", 2))
    end

    it "publishes attributes that give the served cluster at exposedAt after a peek and a change" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 20
      context.set_attribute("city", "Faro")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      expect(expected("Faro", 0)).not_to eq(expected("Lisboa", 0))

      context.publish
      events = context.send(:event_handler).events
      expect(events.length).to eq(1)
      expect(events[0].exposures.map(&:exposed_at)).to eq([ANCHOR + 20])
      expect(collector_cluster(events[0], events[0].exposures[0], "city")).to eq("Lisboa")
      expect(events[0].attributes.map(&:value)).to eq(%w[Lisboa])
    end

    # The batch's attributes would give Faro at the exposure's instant after a rewind: the exposure
    # keeps its instant (no move across a burn window) and is published with what its slot read.
    it "publishes the served cluster after a clock rewind, at the exposing call's instant" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      clock.now = ANCHOR + 30
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 20
      context.set_attribute("city", "Faro")
      clock.now = ANCHOR + 40
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      context.publish
      events = context.send(:event_handler).events
      exposure = events.flat_map { |e| e.exposures || [] }.first
      body = events.find { |e| (e.exposures || []).include?(exposure) }
      expect(exposure.exposed_at).to eq(ANCHOR + 40)
      expect(collector_cluster(body, exposure, "city")).to eq("Lisboa")
    end

    # The read saw an attribute stamped after the exposure's instant (the clock stepped back between
    # them): the separate body carries the read's attributes stamped at exposedAt.
    it "publishes the served cluster when the read's attribute is later than exposedAt" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 30
      context.set_attribute("city", "Lisboa")
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 20
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      context.publish
      body = context.send(:event_handler).events.last
      expect(body.exposures.map(&:exposed_at)).to eq([ANCHOR + 20])
      expect(collector_cluster(body, body.exposures[0], "city")).to eq("Lisboa")
      expect(body.attributes.map { |a| [a.value, a.set_at] }).to eq([["Lisboa", ANCHOR + 20]])
    end

    # The fallback keeps every captured attribute, unrelated ones included; only the cluster-source
    # attribute the read selected is stamped at exposedAt.
    it "keeps unrelated attributes in the rewind fallback body" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 5
      context.set_attribute("tier", "gold")
      clock.now = ANCHOR + 30
      context.set_attribute("city", "Lisboa")
      clock.now = ANCHOR + 31
      context.set_attribute("plan", "pro")
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 20
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 25
      context.set_attribute("city", "Faro")

      context.publish
      body = context.send(:event_handler).events.last
      expect(body.exposures.map(&:exposed_at)).to eq([ANCHOR + 20])
      expect(collector_cluster(body, body.exposures[0], "city")).to eq("Lisboa")
      # An unrelated attribute keeps its own setAt, even one later than exposedAt.
      expect(body.attributes.map { |a| [a.name, a.value, a.set_at] })
        .to eq([["tier", "gold", ANCHOR + 5], ["city", "Lisboa", ANCHOR + 20], ["plan", "pro", ANCHOR + 31]])
    end

    # A later value of a cluster-source attribute that the read skipped (it was in the read's future
    # after a rewind) is left out of the fallback body, so the Collector keeps the served cluster.
    # A selected attribute already earlier than exposedAt keeps its setAt.
    it "drops a later cluster-source value the read skipped from the fallback body" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      clock.now = ANCHOR + 50
      context.set_attribute("city", "Faro")
      clock.now = ANCHOR + 30
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 60
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      context.publish
      body = context.send(:event_handler).events.last
      expect(body.exposures.map(&:exposed_at)).to eq([ANCHOR + 60])
      expect(collector_cluster(body, body.exposures[0], "city")).to eq("Lisboa")
      expect(body.attributes.map { |a| [a.name, a.value, a.set_at] }).to eq([["city", "Lisboa", ANCHOR + 10]])
    end

    # The drop rule matches cluster-source names trimmed, as the Collector does, and covers every
    # declared source: a later " city " value and a later zone value are both left out.
    it "drops later values of every cluster source, matched by trimmed name, from the fallback body" do
      sources = { UNIT_TYPE => "city", "user_id" => "zone" }
      context = create_context(attribute_switchback("city", switchbackClusters: sources),
                               units: { UNIT_TYPE => UID, "user_id" => "u-1" })
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.set_attribute("zone", "Lisboa")
      clock.now = ANCHOR + 50
      context.set_attribute(" city ", "Faro")
      context.set_attribute("zone", "Porto")
      clock.now = ANCHOR + 30
      expect(context.peek_treatment("exp_sb")).to eq(expected("Lisboa", 0))
      clock.now = ANCHOR + 60
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      context.publish
      body = context.send(:event_handler).events.last
      expect(body.attributes.map { |a| [a.name.strip, a.value] }).to eq([%w[city Lisboa], %w[zone Lisboa]])
    end

    # The exposure is not moved to the slot's read instant, so a burn-in window that the exposing
    # call is outside of keeps it in the analysis.
    it "keeps an exposure outside burn-in after a mid-period change" do
      context = create_context(attribute_switchback("city", switchbackBurnInDurationMs: 60_000))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.peek_treatment("exp_sb")
      clock.now = ANCHOR + 120_000
      context.set_attribute("city", "Faro")
      clock.now = ANCHOR + 180_000
      context.treatment("exp_sb")
      context.publish
      events = context.send(:event_handler).events
      exposure = events.flat_map { |e| e.exposures || [] }.first
      expect(exposure.exposed_at).to eq(ANCHOR + 180_000)
      expect(collector_cluster(events.last, exposure, "city")).to eq("Lisboa")
    end

    # The Collector re-selects the serving unit from the batch's units: a unit added after the
    # exposure must not move it or drop it.
    it "publishes an exposure with the units it was served under after a later set_unit" do
      sources = { "user_id" => "tier", UNIT_TYPE => "city" }
      context = create_context(attribute_switchback("city", switchbackClusters: sources))
      clock.now = ANCHOR + 10
      context.set_attribute("tier", "1")
      context.set_attribute("city", "0")
      expect(context.treatment("exp_sb")).to eq(expected("0", 0))
      context.set_unit("user_id", "u-1")
      context.track("goal")
      context.publish

      events = context.send(:event_handler).events
      separate = events.find { |e| e.exposures&.any? }
      expect(separate.units.map(&:type)).to eq([UNIT_TYPE])
      expect(separate.exposures.map(&:unit)).to eq([UNIT_TYPE])
      expect(collector_cluster(separate, separate.exposures[0], "city")).to eq("0")
      # Collector-equivalent selection over the body: only store_id is linked and present.
      body_units = separate.units.to_h { |u| [u.type, u.uid] }
      expect(sources.keys.select { |type| body_units.key?(type) }).to eq([UNIT_TYPE])
      goals = events.find { |e| e.goals&.any? }
      expect(goals.units.map(&:type)).to contain_exactly(UNIT_TYPE, "user_id")
      expect(context.pending_count).to eq(0)
    end

    # A recorded traffic miss is checked the same way: the Collector resolves its cluster too.
    it "publishes a traffic miss with the cluster it was read with after a mid-period change" do
      context = create_context(attribute_switchback("city", trafficSplit: [1.0, 0.0]))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.peek_treatment("exp_sb")
      clock.now = ANCHOR + 20
      context.set_attribute("city", "Faro")
      expect(context.treatment("exp_sb")).to eq(0)
      context.publish
      body = context.send(:event_handler).events.last
      expect(body.exposures.map(&:eligible)).to eq([false])
      expect(collector_cluster(body, body.exposures[0], "city")).to eq("Lisboa")
    end

    def multi_request_context
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.treatment("exp_sb")
      context.set_unit("user_id", "u-1")
      # A same-millisecond change forces a separate switchback body; the goal is the first body.
      context.set_attribute("city", "Faro")
      context.track("goal")
      context
    end

    it "retries only the undelivered request after a later request raises" do
      context = multi_request_context
      publisher = context.send(:event_handler)
      delivered = []
      attempts = 0
      allow(publisher).to receive(:publish) do |_ctx, event|
        attempts += 1
        raise "second request failed" if attempts == 2

        delivered << event
        nil
      end
      expect { context.publish }.to raise_error("second request failed")
      expect(delivered.length).to eq(1)
      expect(delivered.first.goals.map(&:name)).to eq(["goal"])
      expect(context.pending_count).to eq(1)
      context.publish
      expect(delivered.length).to eq(2)
      expect(delivered.last.exposures.map(&:name)).to eq(["exp_sb"])
      # The retried exposure keeps its own request and the cluster it was served.
      expect(collector_cluster(delivered.last, delivered.last.exposures.first, "city")).to eq("Lisboa")
      expect(context.pending_count).to eq(0)
    end

    it "logs the error a raising publisher raises before it propagates, on both paths" do
      [false, true].each do |multi|
        context = multi ? multi_request_context : create_context(attribute_switchback("city"))
        context.track("goal") unless multi
        errors = []
        logger = double("logger")
        allow(logger).to receive(:handle_event) { |type, data| errors << data if type == ContextEventLogger::EVENT_TYPE::ERROR }
        context.send(:event_logger=, logger)
        allow(context.send(:event_handler)).to receive(:publish).and_raise(StandardError, "collector down")
        expect { context.publish }.to raise_error("collector down")
        expect(errors).to eq(["collector down"]), multi.to_s
      end
    end

    # The Collector records every request attribute with an exposure, so a separate body keeps
    # the attributes that are not cluster paths too.
    it "keeps non-cluster attributes in a separate body" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 5
      context.set_attribute("city", "Porto")
      clock.now = ANCHOR + 10
      context.set_attribute("tier", "gold")
      context.set_attribute("city", "Lisboa")
      context.treatment("exp_sb")
      context.set_attribute("city", "Faro")
      context.publish
      body = context.send(:event_handler).events.last
      # Without a rewind the body is every attribute the read saw, earlier cluster values included.
      expect(body.attributes.map { |a| [a.name, a.value] }).to eq([%w[city Porto], %w[tier gold], %w[city Lisboa]])
      expect(collector_cluster(body, body.exposures.first, "city")).to eq("Lisboa")
    end

    # A caller that changes its own String in place after the read does not change the cluster the
    # slot served or the attribute published with its exposure.
    it "keeps the served cluster when the caller mutates the String it set" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      city = +"Lisboa"
      context.set_attribute("city", city)
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      city.replace("Faro")
      expect(expected("Faro", 0)).not_to eq(expected("Lisboa", 0))

      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      context.publish
      body = context.send(:event_handler).events.last
      expect(collector_cluster(body, body.exposures[0], "city")).to eq("Lisboa")
      expect(body.attributes.map(&:value)).to eq(%w[Lisboa])
    end

    # The same for a nested value: the Hash the caller set is copied, a shared child once.
    it "keeps the served cluster when the caller mutates the Hash it set" do
      context = create_context(attribute_switchback("geo/city"))
      clock.now = ANCHOR + 10
      shared = { "name" => +"x" }
      geo = { "city" => +"Lisboa", "a" => shared, "b" => shared }
      context.set_attribute("geo", geo)
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      geo["city"] = "Faro"
      shared["name"] << "y"
      expect(expected("Lisboa", 0)).not_to eq(expected("Faro", 0))

      context.publish
      body = context.send(:event_handler).events.last
      value = body.attributes[0].value
      expect(value["city"]).to eq("Lisboa")
      expect(value["a"]).to equal(value["b"])
      expect(value["a"]).to eq({ "name" => "x" })
      expect(body.exposures.length).to eq(1)
    end

    # A set_attribute that lands after the batch's attributes were checked (another thread, same
    # millisecond, so it would win the Collector's setAt tie) stays out of the checked body.
    it "publishes the batch body its switchback exposures were checked against" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      allow(context).to receive(:separate_switchback_exposures).and_wrap_original do |original, *args|
        original.call(*args).tap { context.set_attribute("city", "Faro") }
      end

      context.publish
      events = context.send(:event_handler).events
      expect(events.length).to eq(1)
      expect(events[0].attributes.map(&:value)).to eq(%w[Lisboa])
      expect(collector_cluster(events[0], events[0].exposures[0], "city")).to eq("Lisboa")
    end

    # A switchback is separated out of a batch that also holds an ordinary exposure.
    it "separates a switchback out of a batch with another exposure" do
      unit = attribute_switchback("city", id: 2, name: "exp_unit", randomizationType: nil,
                                          switchbackClusters: nil, switchbackStartAt: nil)
      context = build_context(data_of([attribute_switchback("city"), unit]), units: { UNIT_TYPE => UID })
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.peek_treatment("exp_sb")
      clock.now = ANCHOR + 20
      context.set_attribute("city", "Faro")
      clock.now = ANCHOR + 30
      context.treatment("exp_sb")
      context.treatment("exp_unit")
      context.publish
      events = context.send(:event_handler).events
      expect(events.length).to eq(2)
      expect(events.map { |e| e.exposures.map(&:name) }).to eq([%w[exp_unit], %w[exp_sb]])
      expect(events.first.attributes.map(&:value)).to eq(%w[Lisboa Faro])
      expect(collector_cluster(events.last, events.last.exposures.first, "city")).to eq("Lisboa")
    end

    # Only an eligible cluster's exposure is separated; an override with no cluster stays in the
    # batch, with the attributes set after it, even when the clock stepped back.
    it "keeps an overridden exposure without a cluster in the batch" do
      context = build_context(data_of([attribute_switchback("city")]), units: { UNIT_TYPE => UID },
                                                                      overrides: { "exp_sb" => 1 })
      clock.now = ANCHOR + 20
      context.treatment("exp_sb")
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Faro")
      context.publish
      events = context.send(:event_handler).events
      expect(events.length).to eq(1)
      expect(events.first.attributes.map(&:value)).to eq(%w[Faro])
    end

    it "stops at the first failed request and keeps all undelivered events" do
      context = multi_request_context
      publisher = context.send(:event_handler)
      failure = StandardError.new("first request failed")
      allow(publisher).to receive(:publish).and_return(failure)
      expect(context.publish).to equal(failure)
      expect(publisher).to have_received(:publish).once
      expect(context.pending_count).to eq(2)
    end

    it "logs each successful publish in order and clears switchback tracking" do
      context = multi_request_context
      logged = []
      logger = double("logger")
      allow(logger).to receive(:handle_event) { |type, event| logged << [type, event] }
      context.send(:event_logger=, logger)
      context.publish
      expect(logged.map(&:first)).to eq([ContextEventLogger::EVENT_TYPE::PUBLISH] * 2)
      expect(logged[0][1].goals.map(&:name)).to eq(["goal"])
      expect(logged[1][1].exposures.map(&:name)).to eq(["exp_sb"])
      expect(context.instance_variable_get(:@switchback_exposures)).to be_nil
      allow(context).to receive(:served_at?).and_call_original
      context.track("next")
      context.publish
      expect(context).not_to have_received(:served_at?)
      expect(context.pending_count).to eq(0)
    end

    it "returns ordinary publishes to the one-request fast path after switchback delivery" do
      context = multi_request_context
      context.publish
      allow(context).to receive(:separate_switchback_exposures).and_call_original
      allow(context).to receive(:dequeue_published).and_call_original
      context.track("ordinary")
      context.publish
      expect(context).not_to have_received(:separate_switchback_exposures)
      expect(context).not_to have_received(:dequeue_published)
    end

    it "preserves the serving unit when a newly added higher priority unit agrees" do
      sources = { "user_id" => "tier", UNIT_TYPE => "city" }
      context = create_context(attribute_switchback("city", switchbackClusters: sources))
      clock.now = ANCHOR + 10
      context.set_attribute("tier", "Lisboa")
      context.set_attribute("city", "Lisboa")
      context.treatment("exp_sb")
      context.set_unit("user_id", "u-1")
      context.publish
      body = context.send(:event_handler).events.last
      expect(body.units.map(&:type)).to eq([UNIT_TYPE])
      expect(body.exposures.map(&:unit)).to eq([UNIT_TYPE])
      expect(collector_cluster(body, body.exposures.first, "city")).to eq("Lisboa")
    end

    # Exposures the batch already attributes correctly share one body.
    it "keeps one publish body when every exposure resolves from the batch" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.treatment("exp_sb")
      context.track("goal")
      context.publish
      expect(context.send(:event_handler).events.length).to eq(1)
    end

    # The exposing call's own instant is kept while the attributes still give the slot's cluster.
    it "keeps the exposing call's instant when the attributes are unchanged" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.peek_treatment("exp_sb")
      clock.now = ANCHOR + 20
      context.treatment("exp_sb")
      expect(published_exposures(context).map(&:exposed_at)).to eq([ANCHOR + 20])
    end

    # Attributes keep their real setAt, as in java-sdk: shifting a write past a same-millisecond
    # cluster read would hide it from every other read in that millisecond (and, with a fixed
    # clock, for good). A write in the exposure's own millisecond ties at the Collector, which
    # takes the later entry; the next period serves the new value.
    it "keeps the real setAt of an attribute written in an exposure's millisecond" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      context.set_attribute("city", "Faro")
      expect(context.send(:attributes).map(&:set_at)).to eq([ANCHOR + 10, ANCHOR + 10])

      clock.now = ANCHOR + HOUR
      expect(context.treatment("exp_sb")).to eq(expected("Faro", 1))
    end

    # A read in the same millisecond as a write sees it, whatever was read before.
    it "lets every read in a millisecond see an attribute set in it" do
      other = attribute_switchback("city", id: 2, name: "exp_other")
      context = build_context(data_of([attribute_switchback("zone", name: "exp_first"), other]), units: { UNIT_TYPE => UID })
      clock.now = ANCHOR + 10
      context.set_attribute("zone", "z")
      context.peek_treatment("exp_first")
      context.set_attribute("city", "Faro")
      expect(context.treatment("exp_other")).to eq(expected("Faro", 0))
      expect(context.pending_count).to eq(1)
    end

    it "re-resolves the period when the cluster path changes" do
      context = create_context(attribute_switchback("city"))
      clock.now = ANCHOR + 10
      context.set_attribute("city", "Lisboa")
      context.set_attribute("geo", { "city" => "Porto" })
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      expect(context.pending_count).to eq(1)

      refresh_to(context, attribute_switchback("city"))
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))
      expect(context.pending_count).to eq(1)

      refresh_to(context, attribute_switchback("geo/city"))
      expect(context.treatment("exp_sb")).to eq(expected("Porto", 0))
      expect(context.pending_count).to eq(2)

      refresh_to(context, attribute_switchback("geo/city", switchbackClusterValues: %w[Porto Faro]))
      expect(context.treatment("exp_sb")).to eq(expected("Porto", 0))
      expect(context.pending_count).to eq(3)
    end

    it "re-keys the period and moves the exposure unit when the linked unit type changes" do
      context = create_context(attribute_switchback("city"), units: { UNIT_TYPE => UID, "user_id" => "user-0002" })
      clock.now = ANCHOR + 1
      context.set_attribute("city", "Lisboa")
      context.set_attribute("ucity", "Faro")
      expect(context.treatment("exp_sb")).to eq(expected("Lisboa", 0))

      refresh_to(context, attribute_switchback("ucity", switchbackClusters: { "user_id" => "ucity" }))
      expect(context.treatment("exp_sb")).to eq(expected("Faro", 0))
      expect(published_exposures(context).map(&:unit)).to eq([UNIT_TYPE, "user_id"])
    end

    it "applies a custom assignment only to units with a cluster key" do
      keyed = create_context(attribute_switchback("city"))
      keyed.set_attribute("city", "Lisboa")
      keyed.set_custom_assignment("exp_sb", 2)
      expect(keyed.treatment("exp_sb")).to eq(2)

      unkeyed = create_context(attribute_switchback("city"))
      unkeyed.set_custom_assignment("exp_sb", 2)
      expect(unkeyed.treatment("exp_sb")).to eq(0)
    end

    # Inertness: a unit experiment carrying every switchback field serves and publishes exactly
    # what the same experiment without them does.
    it "ignores cluster fields on unit experiments" do
      [nil, "unit"].each do |type|
        split_rule = '{"rules":[{"type":"split","environments":[],"percentages":"34/33/33"}]}'
        unit = attribute_switchback("city", randomizationType: type,
                                            switchbackClusters: { "user_id" => "city", UNIT_TYPE => "'x" },
                                            switchbackClusterValues: ["nothing"], switchbackPeriodMs: 0,
                                            assignmentRules: split_rule)
        reference = unit.reject { |key, _| key.to_s.start_with?("switchback") }
        published = [unit, reference].map do |experiment|
          clock.now = ANCHOR - HOUR
          context = create_context(experiment, units: { UNIT_TYPE => UID, "user_id" => "u" })
          context.set_attribute("city", "Lisboa")
          first = context.treatment("exp_sb")
          (1...6).each do |i|
            clock.now = ANCHOR - HOUR + i * HOUR
            expect(context.treatment("exp_sb")).to eq(first)
          end
          published_exposures(context)
        end
        expect(published[0].length).to eq(1)
        expect(published[0][0].eligible).to be(true)
        expect(published[0][0].rule_override).to be(true)
        expect(published[0][0].exposed_at).to eq(ANCHOR - HOUR)
        expect(published[0]).to eq(published[1])
      end
    end
  end

  # Port of the Collector's ContextAPISwitchbackTest ClusterRule section (absmartly/abs
  # 9bd2b5ca35) through the public Context API, as java-sdk ContextSwitchbackClusterRuleTest
  # does: switchback "sbc" (id 900, 34/33/33, 1h) linked to user_id at "profile/store" and to
  # session_id at "session_store", declared session_id first (unit type id order) although the
  # user_id link was added first. A context holds one uid per unit type, so the declared source
  # order alone decides which unit serves.
  RSpec.describe "Context switchback cluster rules" do
    include SwitchbackSpecSupport

    PERIOD = 5
    NOW = ANCHOR + PERIOD * HOUR + 17 * 60_000
    RULE_SEED_HI = 0x1234
    RULE_SEED_LO = 0x5678abcd
    RULE_TRAFFIC_SEED_HI = 7
    RULE_TRAFFIC_SEED_LO = 11
    SESSION = "session_id"
    USER = "user_id"

    let(:clock) { SwitchbackSpecSupport::MutableClock.new(NOW) }
    let(:links) { [[USER, "profile/store"], [SESSION, "session_store"]] }
    let(:extra) { {} }

    def switchback_experiment(name, id, unit_type, split)
      parts = split.split("/").map { |p| Integer(p) / 100.0 }
      {
        id: id, name: name, unitType: unit_type, iteration: 1, seedHi: RULE_SEED_HI, seedLo: RULE_SEED_LO, split: parts,
        variants: parts.each_index.map { |i| { name: i.to_s, config: "{\"sbc.config\":\"test config #{i}\"}" } },
        trafficSeedHi: RULE_TRAFFIC_SEED_HI, trafficSeedLo: RULE_TRAFFIC_SEED_LO, trafficSplit: [0.0, 1.0], fullOnVariant: 0,
        applications: [{ name: "website" }], audienceStrict: false, audience: nil,
        randomizationType: "switchback", switchbackStartAt: ANCHOR, switchbackPeriodMs: HOUR,
        switchbackDesignType: "balanced_block"
      }
    end

    def unit_experiment(name, id, unit_type)
      switchback_experiment(name, id, unit_type, "50/50").merge(
        randomizationType: nil, switchbackStartAt: nil, switchbackPeriodMs: nil, switchbackDesignType: nil,
        variants: [{ name: "0", config: nil }, { name: "1", config: nil }]
      )
    end

    # switchbackClusters in declared (unit type id ascending) order: session_id before user_id.
    def clusters
      return nil if links.empty?

      [SESSION, USER, "device_id"].each_with_object({}) do |type, map|
        links.each { |link| map[link[0]] = link[1] if link[0] == type }
      end
    end

    def experiment
      switchback_experiment("sbc", 900, USER, "34/33/33").merge(switchbackClusters: clusters).merge(extra)
    end

    def scheduled(key)
      draw(key, PERIOD, RULE_SEED_HI, RULE_SEED_LO, 3)
    end

    def create_context(attributes, experiments, units)
      @logger = SwitchbackSpecSupport::Logger.new
      context = build_context(data_of(experiments), units: units, logger: @logger)
      context.set_attributes(attributes) unless attributes.nil?
      context
    end

    Assigned = Struct.new(:unit, :eligible, :variant, :full_on, :rule_override, :silent, :config, :exposures)

    def sbc(attributes, units)
      sbc_with(attributes, [experiment], units)
    end

    # Every other experiment resolves (and exposes) first; only "sbc" exposures are returned.
    def sbc_with(attributes, experiments, units)
      context = create_context(attributes, experiments, units)
      experiments.each { |other| context.treatment(other[:name]) unless other[:name] == "sbc" }
      variant = context.treatment("sbc")
      resolution = context.send(:switchback_resolution_for_test, "sbc")
      expect(resolution).not_to be_nil
      config = context.variable_value(:"sbc.config", nil)
      exposures = @logger.exposures.select { |e| e.name == "sbc" }
      # Keyed on the serving status: a strict mismatch is not assigned yet is still listed.
      if resolution.serving.status == Absmartly::Switchback::Serving::ABSENT
        expect(variant).to eq(0)
        expect(config).to be_nil
        expect(exposures).to be_empty
        return nil
      end
      Assigned.new(resolution.unit_type, resolution.eligible, variant, resolution.full_on, resolution.rule_override,
                   resolution.switchback_silent, config, exposures)
    end

    # An ineligible cluster is still an assignment, as control, under the first linked unit in
    # declared order, with no exposure.
    def expect_ineligible(attributes, expected_unit, units)
      assignment = sbc(attributes, units)
      expect(assignment).not_to be_nil, attributes.inspect
      expect([assignment.unit, assignment.eligible, assignment.silent, assignment.variant, assignment.full_on,
              assignment.rule_override, assignment.config]).to eq([expected_unit, false, true, 0, false, false,
                                                                   "test config 0"])
      expect(assignment.exposures).to be_empty, attributes.inspect
    end

    def store(value)
      { "store" => value }
    end

    it "returns only a legacy ineligible control for a missing or unreadable cluster configuration" do
      ["null-cluster", "missing-links", "unreadable-path", "geo.city", "'geo.city'", "\"geo.city\"",
       "unknown-unit"].each do |broken|
        links.clear
        case broken
        when "unreadable-path" then links << [SESSION, "'geo"]
        when "unknown-unit"
          # A readable map whose only linked type (device_id) is absent from the context.
          links << ["device_id", "session_store"]
          expect(sbc({ "session_store" => "s-1" }, { SESSION => "x1", USER => "u1" })).to be_nil
          next
        when "null-cluster" then nil
        when "missing-links" then extra[:switchbackClusters] = {}
        else links << [SESSION, broken]
        end
        attributes = { "geo" => { "city" => "Porto" }, "geo.city" => "Faro", "session_store" => "s-1" }
        # The declared unit (user_id) only identifies an ineligible control.
        expect_ineligible(attributes, USER, { SESSION => "x1", USER => "u1" })
        expect(sbc(attributes, { SESSION => "x1" })).to be_nil, broken
        extra.clear
      end
    end

    it "uses the serving uid for traffic, not the experiment's unit" do
      extra[:trafficSplit] = [0.6, 0.4]
      ordinary = unit_experiment("ordinary", 901, USER)
      witnesses = []
      (0...1000).each do |i|
        uid = "traffic-#{i}"
        slot = VariantAssigner.new(uid).assign([0.6, 0.4], RULE_TRAFFIC_SEED_HI, RULE_TRAFFIC_SEED_LO).zero? ? 0 : 1
        witnesses[slot] ||= uid
        break if witnesses.compact.length == 2
      end
      expect(witnesses.compact.length).to eq(2)
      key = "s-18"
      expect(scheduled(key)).not_to eq(0)
      [false, true].each do |serving_eligible|
        assignment = sbc_with({ "session_store" => key, "profile" => store(key) }, [experiment, ordinary],
                              { SESSION => witnesses[serving_eligible ? 1 : 0],
                                USER => witnesses[serving_eligible ? 0 : 1] })
        expect(assignment.unit).to eq(SESSION)
        expect(assignment.eligible).to eq(serving_eligible)
        expect(assignment.variant).to eq(serving_eligible ? scheduled(key) : 0)
        # A traffic miss on an eligible cluster is still recorded, under the serving unit.
        expect(assignment.exposures.map { |e| [e.unit, e.eligible] }).to eq([[SESSION, serving_eligible]])
      end
    end

    it "serves the value of one matching unit" do
      assignment = sbc({ "profile" => store("s-17") }, { USER => "u1" })
      expect([assignment.eligible, assignment.unit, assignment.variant]).to eq([true, USER, scheduled("s-17")])
    end

    it "lists a strict audience mismatch on an eligible cluster as control and records it" do
      extra.merge!(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true)
      assignment = sbc({ "session_store" => "s-17" }, { SESSION => "x1" })
      expect([assignment.unit, assignment.eligible, assignment.silent, assignment.variant])
        .to eq([SESSION, true, false, 0])
      expect(assignment.exposures.map { |e| [e.audience_mismatch, e.assigned] }).to eq([[true, false]])
    end

    it "serves the value two agreeing units give" do
      assignment = sbc({ "profile" => store("s-17"), "session_store" => "s-17" }, { USER => "u1", SESSION => "x1" })
      expect([assignment.eligible, assignment.variant]).to eq([true, scheduled("s-17")])
    end

    it "makes two disagreeing units ineligible" do
      # session_id is first in declared order whatever the unit order.
      expect_ineligible({ "profile" => store("s-17"), "session_store" => "s-18" }, SESSION,
                        { USER => "u1", SESSION => "x1" })
    end

    # A context holds one uid per unit type, so only the single-unit path is reproducible.
    it "serves one unit of a type with one path" do
      key = "s-17"
      expect(scheduled(key)).not_to eq(0)
      context = create_context({ "session_store" => key }, [experiment], { SESSION => "x1" })
      expect { context.set_unit(SESSION, "x2") }.to raise_error(IllegalStateException)

      assignment = sbc({ "session_store" => key }, { SESSION => "x1" })
      expect([assignment.eligible, assignment.variant]).to eq([true, scheduled(key)])
    end

    it "does not apply without a matching unit" do
      expect(sbc({ "session_store" => "s-1" }, { "device_id" => "d1" })).to be_nil
      expect(sbc({ "session_store" => "s-1" }, {})).to be_nil
    end

    it "makes a matching unit without a value ineligible" do
      expect_ineligible({ "other" => "s-1" }, USER, { USER => "u1" })
      expect_ineligible({ "other" => "s-1" }, SESSION, { USER => "u1", SESSION => "x1" })
    end

    it "makes values that are neither strings nor integers ineligible" do
      [1.5, 3.0, true, { "a" => 1 }, ["a"], ""].each do |value|
        expect_ineligible({ "session_store" => value }, SESSION, { SESSION => "x1" })
      end
    end

    it "keys whole numbers by their decimal text" do
      expect(scheduled("17")).not_to eq(0)
      assignment = sbc({ "session_store" => 17 }, { SESSION => "x1" })
      expect([assignment.eligible, assignment.variant]).to eq([true, scheduled("17")])
      # Equal to the string "17" from another unit type, so the two agree.
      expect(sbc({ "session_store" => 17, "profile" => store("17") }, { SESSION => "x1", USER => "u1" }).eligible)
        .to be(true)
    end

    it "reads nested and array paths" do
      links.replace([[SESSION, "items/1/store"]])
      assignment = sbc({ "items" => [store("a"), store("b")] }, { SESSION => "x1" })
      expect(assignment.variant).to eq(scheduled("b"))
      expect(scheduled("a")).not_to eq(scheduled("b"))
    end

    it "exposes the first matching unit in declared order whatever the unit order" do
      key = "s-18"
      expect(scheduled(key)).not_to eq(0)
      assignment = sbc({ "profile" => store(key), "session_store" => key }, { USER => "u1", SESSION => "x1" })
      expect([assignment.unit, assignment.exposures[0].unit, assignment.variant]).to eq([SESSION, SESSION, scheduled(key)])
    end

    it "never publishes an exposure for an ineligible cluster" do
      published = SwitchbackSpecSupport::Publisher.new
      @logger = SwitchbackSpecSupport::Logger.new
      context = build_context(data_of([experiment]), units: { USER => "u1", SESSION => "x1" },
                                                     publisher: published, logger: @logger)
      context.set_attributes({ "session_store" => "a", "profile" => store("b") })
      expect(context.treatment("sbc")).to eq(0)
      expect(context.pending_count).to eq(0)
      context.publish
      expect(published.events).to be_empty
      expect(@logger.exposures).to be_empty
    end

    it "does not serve a unit without a value even if it is first in declared order" do
      key = "s-17"
      expect(scheduled(key)).not_to eq(0)
      assignment = sbc({ "profile" => store(key) }, { SESSION => "x1", USER => "u1" })
      expect([assignment.unit, assignment.exposures[0].unit, assignment.variant]).to eq([USER, USER, scheduled(key)])
    end

    it "makes a value outside the allow-list ineligible" do
      extra[:switchbackClusterValues] = %w[s-1 s-2]
      expect_ineligible({ "session_store" => "s-3" }, SESSION, { SESSION => "x1" })
      allowed = sbc({ "session_store" => "s-2" }, { SESSION => "x1" })
      expect([allowed.eligible, allowed.variant]).to eq([true, scheduled("s-2")])
    end

    it "assigns every value with a null allow-list" do
      extra[:switchbackClusterValues] = nil
      20.times do |i|
        assignment = sbc({ "session_store" => "s-#{i}" }, { SESSION => "x1" })
        expect([assignment.eligible, assignment.variant]).to eq([true, scheduled("s-#{i}")])
      end
    end

    it "does not fall back to the experiment's unit without a linked unit" do
      links.replace([[SESSION, "session_store"]])
      key = "s-17"
      expect(scheduled(key)).not_to eq(0)
      expect(sbc({ "session_store" => key, "profile" => store(key) }, { USER => "u1" })).to be_nil
      linked = sbc({ "session_store" => key }, { USER => "u1", SESSION => "x1" })
      expect([linked.unit, linked.variant]).to eq([SESSION, scheduled(key)])
    end

    # The Collector's wire-rule oracle SdkSwitchbackRule, transcribed: period from the anchor
    # re-ceiled to the hour, traffic on the serving uid's hash, then the draw over the key.
    module SdkSwitchbackRule
      def self.period_index(experiment, now)
        start_at = experiment[:switchbackStartAt]
        period_ms = experiment[:switchbackPeriodMs]
        return nil if start_at.nil? || period_ms.nil? || period_ms <= 0 || experiment[:split].length < 2

        anchor = -((-start_at).div(HOUR)) * HOUR
        now < anchor ? nil : (now - anchor).div(period_ms)
      end

      # [variant, eligible]
      def self.evaluate(experiment, uid, cluster_key, now)
        period = period_index(experiment, now)
        return [0, false] if cluster_key.nil? || period.nil?

        eligible = VariantAssigner.new(uid).assign(experiment[:trafficSplit], experiment[:trafficSeedHi],
                                                   experiment[:trafficSeedLo]) == 1
        return [0, false] unless eligible

        seed = (experiment[:seedHi] << 32) | (experiment[:seedLo] & 0xffffffff)
        [Absmartly::Switchback::Assigner.assign(cluster_key, period, seed, experiment[:split].length), true]
      end
    end

    def grid_context(cluster, uid, key)
      links.replace([[SESSION, "session_store"]])
      extra[:switchbackClusterValues] = nil
      case cluster
      when :disagreeing_second_source
        links << [USER, "profile/store"]
        create_context({ "session_store" => key, "profile" => store("#{key}-other") }, [experiment],
                       { SESSION => uid, USER => "u-#{uid}" })
      when :missing_value then create_context({ "other" => key }, [experiment], { SESSION => uid })
      when :filtered_value
        extra[:switchbackClusterValues] = ["#{key}-allowed"]
        create_context({ "session_store" => key }, [experiment], { SESSION => uid })
      else create_context({ "session_store" => key }, [experiment], { SESSION => uid })
      end
    end

    it "matches the SdkSwitchbackRule wire-rule parity grid" do
      counts = Hash.new(0)
      %i[single disagreeing_second_source missing_value filtered_value].each do |cluster|
        [ANCHOR, ANCHOR + 7 * HOUR].each do |anchor|
          [HOUR, 2 * HOUR, 24 * HOUR].each do |period_ms|
            6.times do |u|
              uid = "uid-#{u}"
              ["s-1", "s-2", "42", "Lisboa"].each do |key|
                [anchor - HOUR, anchor - 1, anchor, anchor + period_ms - 1, anchor + period_ms,
                 anchor + 3 * period_ms + 5, anchor + 11 * period_ms].each do |now|
                  extra.merge!(trafficSplit: [0.3, 0.7], switchbackStartAt: anchor, switchbackPeriodMs: period_ms)
                  clock.now = now
                  oracle_key = cluster == :single ? key : nil
                  context = grid_context(cluster, uid, key)
                  oracle = SdkSwitchbackRule.evaluate(experiment, uid, oracle_key, now)
                  message = [cluster, anchor, period_ms, uid, key, now].join("/")
                  expect(context.treatment("sbc")).to eq(oracle[0]), message
                  expect(context.send(:switchback_resolution_for_test, "sbc").eligible).to eq(oracle[1]), message
                  # Before the anchor nothing is recorded; from it a keyed cluster records one
                  # exposure whose eligibility is the oracle's (a traffic miss included).
                  recorded = !oracle_key.nil? && now >= anchor
                  expect(@logger.exposures.length).to eq(recorded ? 1 : 0), message
                  expect(@logger.exposures[0].eligible).to eq(oracle[1]), message if recorded
                  next unless cluster == :single

                  counts[oracle[1]] += 1
                  counts[:traffic_miss] += 1 if !oracle[1] && now >= anchor
                end
              end
            end
          end
        end
      end
      expect(counts[true]).to be > 100
      expect(counts[false]).to be > 100
      expect(counts[:traffic_miss]).to be > 0

      # The deliberate divergence: an anchor off the hour is unservable, while the transcribed
      # oracle would re-ceil it and draw.
      unaligned = ANCHOR + 7 * HOUR + 1
      extra.merge!(trafficSplit: [0.0, 1.0], switchbackStartAt: unaligned, switchbackPeriodMs: HOUR)
      clock.now = ANCHOR + 8 * HOUR + 5
      expect(SdkSwitchbackRule.period_index(experiment, clock.now)).not_to be_nil
      expect(SdkSwitchbackRule.evaluate(experiment, "uid-0", "s-1", clock.now)[1]).to be(true)
      context = grid_context(:single, "uid-0", "s-1")
      expect(context.treatment("sbc")).to eq(0)
      expect(context.send(:switchback_resolution_for_test, "sbc").eligible).to be(false)
      expect(@logger.exposures).to be_empty
    end
  end
end
