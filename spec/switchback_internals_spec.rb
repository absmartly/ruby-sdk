# frozen_string_literal: true

require "json"
require "absmartly/switchback"
require "switchback_support"

# Ports of java-sdk SwitchbackAssignerGoldenVectorsTest, SwitchbackAttributePathTest and
# SwitchbackServingTest (core-api/src/test/java/com/absmartly/sdk/internal).
module SwitchbackInternalsSpec
  Assigner = Absmartly::Switchback::Assigner
  AttributePath = Absmartly::Switchback::AttributePath
  ClusterKeys = Absmartly::Switchback::ClusterKeys
  Serving = Absmartly::Switchback::Serving
  LONG_MIN = -(2**63)
  LONG_MAX = (2**63) - 1

  def self.fixture(name)
    File.read(File.join(__dir__, "fixtures", "resources", "switchback", name))
  end

  # Fixture copied byte-for-byte from absmartly/abs 9bd2b5ca35
  # lib/utils/src/test/resources/switchback/golden-vectors.json (git blob b314abeb9e97),
  # as java-sdk vendors it.
  RSpec.describe "Switchback assigner" do
    let(:vectors) { JSON.parse(SwitchbackInternalsSpec.fixture("golden-vectors.json")) }

    # The platform hashes a numeric cluster unit as its decimal text; strings pass through.
    def cluster_unit(value)
      expect(value).to be_a(String).or be_a(Integer)
      value.to_s
    end

    # 64-bit fields are decimal strings; a number would mean a lossy encoding.
    def exact_long(value)
      expect(value).to be_a(String)
      Integer(value, 10)
    end

    it "is the byte-identical platform fixture" do
      bytes = SwitchbackInternalsSpec.fixture("golden-vectors.json").b
      expect(Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")).to start_with("b314abeb9e97")
    end

    it "matches every assignSwitchback golden vector" do
      cases = vectors["assignSwitchback"]
      expect(cases.length).to eq(882)
      arm_counts = []
      boundary = 0
      cases.each do |c|
        period = exact_long(c["periodIndex"])
        seed = exact_long(c["seed"])
        arm_counts << c["armCount"]
        boundary += 1 if [LONG_MIN, LONG_MAX].include?(period) || [LONG_MIN, LONG_MAX].include?(seed)
        expect(Assigner.assign(cluster_unit(c["clusterUnit"]), period, seed, c["armCount"]))
          .to eq(c["expectedVariant"]), c.to_s
      end
      expect(arm_counts.uniq).to include(2, 3, 10)
      expect(boundary).to be > 0
    end

    it "matches every fisherYatesPermutation golden vector" do
      cases = vectors["fisherYatesPermutation"]
      expect(cases.length).to eq(504)
      cases.each do |c|
        base = Assigner.base_hash(cluster_unit(c["clusterUnit"]), exact_long(c["cycleIndex"]), exact_long(c["seed"]))
        expect(Assigner.fisher_yates_permutation(c["armCount"], base)).to eq(c["expectedPermutation"]), c.to_s
      end
    end

    it "covers every arm exactly once per cycle" do
      [2, 3, 10].each do |arms|
        (-3...20).each do |cycle|
          variants = (0...arms).map { |slot| Assigner.assign("store_42", cycle * arms + slot, 0x1234_5678_9abc, arms) }
          expect(variants.sort).to eq((0...arms).to_a)
        end
      end
    end

    it "rejects fewer than two arms" do
      expect { Assigner.assign("u", 0, 0, 1) }.to raise_error(ArgumentError)
      expect { Assigner.fisher_yates_permutation(0, 0) }.to raise_error(ArgumentError)
    end

    # The cycle is Java's floorDiv(period, arms) and the slot its floorMod, including negative
    # periods and the 64-bit bounds: every period of one cycle draws from that cycle's permutation.
    it "floors the cycle and slot of negative and boundary periods" do
      # [period, arms, floorDiv, floorMod], written out rather than computed.
      [[-1, 2, -1, 1], [-4, 3, -2, 2], [-11, 10, -2, 9], [LONG_MIN, 3, -3_074_457_345_618_258_603, 1],
       [LONG_MAX, 10, 922_337_203_685_477_580, 7]].each do |period, arms, cycle, slot|
        permutation = Assigner.fisher_yates_permutation(arms, Assigner.base_hash("store-42", cycle, 12_345))
        expect(Assigner.assign("store-42", period, 12_345, arms)).to eq(permutation[slot]), [period, arms].inspect
      end
      # Truncating toward zero would draw from cycle 0 instead of cycle -1.
      expect(Assigner.assign("store-42", -1, 12_345, 2)).to eq(0)
      expect(Assigner.fisher_yates_permutation(2, Assigner.base_hash("store-42", 0, 12_345))[1]).to eq(1)
    end
  end

  # Fixture copied byte-for-byte from absmartly/abs 9bd2b5ca35
  # collector/src/test/resources/switchback/attribute-path-cases.json (git blob 7b1d3fed5985),
  # as java-sdk vendors it.
  RSpec.describe "Switchback attribute paths" do
    def parse(path)
      AttributePath.parse_supported(path)
    end

    it "is the byte-identical platform fixture" do
      bytes = SwitchbackInternalsSpec.fixture("attribute-path-cases.json").b
      expect(Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")).to start_with("7b1d3fed5985")
    end

    it "matches every path case" do
      fixture = JSON.parse(SwitchbackInternalsSpec.fixture("attribute-path-cases.json"))
      cases = fixture["cases"]
      expect(cases.length).to eq(7)
      cases.each do |c|
        path = parse(c["path"])
        if c["supported"]
          expect(path).not_to be_nil, c.to_s
          expect(path.resolve(fixture["attributes"])).to eq(c["value"]), c.to_s
        else
          expect(path).to be_nil, c.to_s
        end
      end
    end

    it "reads quoted segments as literal keys" do
      attributes = { "geo" => { "0" => "zero", "a/b" => "slash" } }
      expect(parse("geo/'0'").resolve(attributes)).to eq("zero")
      expect(parse("geo/\"a/b\"").resolve(attributes)).to eq("slash")
    end

    # An unterminated quote anywhere, or a '.' anywhere, quoted or not.
    it "rejects malformed paths" do
      ["geo/'0", "'geo", "\"geo/city", "geo/\"", "geo.city", "geo/a.b", "a./b", ".", "items/0.5/city",
       "'geo.city'", "\"geo.city\"", "geo/'a.b'"].each do |path|
        expect(parse(path)).to be_nil, path
      end
    end

    it "collapses separators" do
      attributes = { "geo" => { "city" => "Porto" } }
      expect(parse("/geo//city/").resolve(attributes)).to eq("Porto")
      expect(parse("geo").resolve(attributes)).to eq(attributes["geo"])
    end

    it "rejects unsupported paths" do
      [nil, "", "/", "//", "0/city", "items/0", "items/0/1/city", "items/-1/city", "'", 7, :geo].each do |path|
        expect(parse(path)).to be_nil, path.inspect
      end
    end

    it "reads lists only with index segments and maps only with key segments" do
      attributes = { "items" => [{ "city" => "Lisbon" }], "geo" => { "0" => { "city" => "zero" } },
                     "name" => "scalar" }
      expect(parse("geo/0/city").resolve(attributes)).to be_nil
      expect(parse("items/1/city").resolve(attributes)).to be_nil
      expect(parse("name/x").resolve(attributes)).to be_nil
      expect(parse("missing/x").resolve(attributes)).to be_nil
      expect(parse("items/-0/city").resolve(attributes)).to eq("Lisbon")
    end

    it "gives no key for cyclic or too-deep values" do
      path = parse("geo/city")

      cyclic = { "city" => "Porto" }
      cyclic["self"] = cyclic
      expect(path.resolve_attribute(cyclic)).to be_nil

      outer = { "city" => "Porto" }
      outer["items"] = [[outer]]
      expect(path.resolve_attribute(outer)).to be_nil

      # 65 nested maps: one past the depth bound.
      deep = { "leaf" => "x" }
      64.times { deep = { "city" => "Porto", "next" => deep } }
      expect(path.resolve_attribute(deep)).to be_nil
      expect(path.resolve_attribute(deep["next"])).to eq("Porto")

      # A value reached twice through siblings is not a cycle.
      shared = { "a" => "b" }
      expect(path.resolve_attribute({ "city" => "Porto", "x" => shared, "y" => shared })).to eq("Porto")
    end

    # Values are read through their JSON encoding, as the Collector reads the published
    # attribute: Symbol keys and values become strings, a Float stays a Float.
    it "reads values through their JSON encoding" do
      path = parse("geo/city")
      expect(path.resolve_attribute({ geo: :x, city: :Porto })).to eq("Porto")
      expect(path.resolve_attribute({ "city" => 3.0 })).to eq(3.0)
      expect(path.resolve_attribute({ "city" => 2**70 })).to eq(2**70)
      expect(parse("geo").resolve_attribute(:lisboa)).to eq("lisboa")
      expect(parse("geo").resolve_attribute(Float::NAN)).to be_nil
    end

    it "parses index segments as Guava Ints.tryParse does" do
      expect(%w[0 -0 007 2147483647 -2147483648].map { |s| AttributePath.try_parse_int(s) })
        .to eq([0, 0, 7, 2_147_483_647, -2_147_483_648])
      ["", "-", "+1", "1a", " 1", "2147483648", "-2147483649", "99999999999999999999", "٠", "1.0", "1\n"]
        .each { |s| expect(AttributePath.try_parse_int(s)).to be_nil, s.inspect }
    end
  end

  # The owner's cluster-value rule: a non-empty String as-is, a whole-number Integer as its
  # base-10 text; every Float (3.0 included), boolean, object, array, "" and nil give none.
  RSpec.describe "Switchback cluster keys" do
    it "keys strings as-is and integers by their decimal text" do
      expect(ClusterKeys.normalize("s-1")).to eq("s-1")
      expect(ClusterKeys.normalize(17)).to eq("17")
      expect(ClusterKeys.normalize(-5)).to eq("-5")
      expect(ClusterKeys.normalize(2**64)).to eq("18446744073709551616")
    end

    it "gives no key for anything else" do
      values = [nil, "", true, false, 3.0, 1.5, Float::INFINITY, Rational(3, 1), :sym, { "a" => 1 }, ["a"]]
      # A bundled gem, not in the Gemfile, from Ruby 3.4.
      values << BigDecimal("3") if SwitchbackSpecSupport.big_decimal?
      values.each { |value| expect(ClusterKeys.normalize(value)).to be_nil, value.inspect }
    end
  end

  RSpec.describe "Switchback serving" do
    def resolve(types, paths, allowed, units, attributes)
      Serving.resolve(types, paths.map { |p| AttributePath.parse_supported(p) }, allowed, units) do |path|
        path.resolve(attributes)
      end
    end

    # The declared source order decides, not the order of the units.
    it "lets the source order decide whatever the unit order" do
      serving = resolve(%w[session_id user_id], %w[session_store user_store], nil,
                        { "user_id" => "u1", "session_id" => "x1" },
                        { "session_store" => "s-1", "user_store" => "s-1" })
      expect([serving.status, serving.unit_type, serving.cluster_key]).to eq([Serving::ELIGIBLE, "session_id", "s-1"])
    end

    it "skips a unit without a value, and a disagreement is ineligible under the first unit" do
      skipped = resolve(%w[session_id user_id], %w[session_store user_store], nil,
                        { "session_id" => "x1", "user_id" => "u1" }, { "user_store" => "s-2" })
      expect([skipped.status, skipped.unit_type, skipped.cluster_key]).to eq([Serving::ELIGIBLE, "user_id", "s-2"])

      disagree = resolve(%w[session_id user_id], %w[session_store user_store], nil,
                         { "session_id" => "x1", "user_id" => "u1" },
                         { "session_store" => "s-1", "user_store" => "s-2" })
      expect([disagree.status, disagree.unit_type, disagree.cluster_key]).to eq([Serving::INELIGIBLE, "session_id", nil])
    end

    it "is absent without a linked unit" do
      expect(resolve(%w[session_id], %w[session_store], nil, { "user_id" => "u" }, {}).status).to eq(Serving::ABSENT)
    end

    it "admits every value with a nil or empty allow-list" do
      expect(Serving.allowed?(nil, "a")).to be(true)
      expect(Serving.allowed?([], "a")).to be(true)
      expect(Serving.allowed?(%w[b], "a")).to be(false)
      expect(Serving.allowed?(%w[b a], "a")).to be(true)
      expect(Serving.allowed?([17], "17")).to be(true)
      expect(Serving.allowed?("a", "a")).to be(false)
      # Scalars match their JSON text, as Jackson coerces them into java-sdk's String[].
      expect(Serving.allowed?([true], "true")).to be(true)
      expect(Serving.allowed?([1.5], "1.5")).to be(true)
      expect(Serving.allowed?([nil, { "a" => "a" }, ["a"], Float::NAN], "a")).to be(false)
      expect(Serving.allowed?([{ "a" => "a" }], '{"a"=>"a"}')).to be(false)
      expect(Serving.allowed?([["a"]], '["a"]')).to be(false)
    end

    it "keeps the declared cluster order" do
      clusters = { "user_id" => "u", "session_id" => "s", "device_id" => "d" }
      expect(Serving.source_types(clusters)).to eq(%w[user_id session_id device_id])
      expect(Serving.source_types({ user_id: "u" })).to eq(%w[user_id])
      expect(Serving.source_types({})).to be_nil
      expect(Serving.source_paths({ "user_id" => "u", "session_id" => "'x" })).to be_nil
      expect(Serving.source_paths({ "user_id" => nil })).to be_nil
    end
  end
end
