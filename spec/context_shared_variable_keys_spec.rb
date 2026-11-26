# frozen_string_literal: true

require "context"
require "context_config"
require "audience_matcher"
require "default_audience_deserializer"
require "default_context_data_deserializer"
require "default_variable_parser"
require "json/context_data"

# A variable key defined by several experiments, as java-sdk
# Context.getVariableAssignment resolves it: the candidates are walked in
# experiment id order, the first one the unit is assigned, overridden or
# rule-assigned in wins, and only that one is exposed. A winner whose variant
# lacks the key gives the caller default; the walk never moves on to a later
# candidate because of the arm the unit got.
module ContextSharedVariableKeysSpec
  RSpec.describe "Context shared variable keys" do
    UNIT_TYPE = "session_id"
    UID = "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
    # split [0.5, 0.5] with seeds 100/200 gives UID variant 1.
    VARIANT = 1
    # split [0.1, 0.9] with seeds 13/111 holds UID out (arm 0); 1/222 does not (arm 1).
    HOLDING_OUT = [13, 111].freeze
    NOT_HOLDING_OUT = [1, 222].freeze
    US_ONLY = '{"filter":[{"eq":[{"var":"country"},{"value":"US"}]}]}'
    US_RULE = JSON.generate(rules: [{ name: "US", type: "assign",
                                      conditions: { and: [{ eq: [{ var: "country" }, { value: "US" }] }] },
                                      environments: [], variant: 0 }])

    let(:clock) { Time.at(1620000000000 / 1000) }
    let(:published) { [] }
    let(:event_handler) do
      handler = double("ContextPublisher")
      allow(handler).to receive(:publish) do |_ctx, event|
        published << event
        OpenStruct.new(success?: true)
      end
      handler
    end
    let(:event_logger) do
      logger = double("ContextEventLogger")
      allow(logger).to receive(:handle_event)
      logger
    end

    def experiment(id, name, configs: ['{"color":"control_%d"}', '{"color":"treatment_%d"}'], unit_type: UNIT_TYPE,
                   **extra)
      {
        id: id, name: name, unitType: unit_type, iteration: 1, seedHi: 100, seedLo: 200, split: [0.5, 0.5],
        trafficSeedHi: 1, trafficSeedLo: 2, trafficSplit: [0.0, 1.0], fullOnVariant: 0,
        applications: [{ name: "website" }], audienceStrict: false, audience: nil,
        variants: configs.each_with_index.map { |c, i| { name: ("A".ord + i).chr, config: c && format(c, id) } }
      }.merge(extra)
    end

    def strict_mismatch(id, name)
      experiment(id, name, audienceStrict: true, audience: US_ONLY)
    end

    def no_unit(id, name)
      experiment(id, name, unit_type: "user_id")
    end

    def holdout(id, name, seeds)
      {
        id: id, name: name, unitType: UNIT_TYPE, iteration: 1, seedHi: seeds[0], seedLo: seeds[1], split: [0.1, 0.9],
        trafficSeedHi: 0, trafficSeedLo: 0, trafficSplit: [0.0, 1.0], fullOnVariant: 0, applications: [],
        variants: [{ name: "A", config: nil }, { name: "B", config: nil }], audienceStrict: false, audience: nil,
        holdoutType: "full"
      }
    end

    def create_context(experiments, holdouts: nil, overrides: {}, country: "GB")
      payload = { experiments: experiments }
      payload[:holdouts] = holdouts unless holdouts.nil?
      json = JSON.generate(payload)
      data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
      config = ContextConfig.create
      config.set_units(UNIT_TYPE => UID)
      config.set_overrides(overrides)
      context = Context.create(clock, config, OpenStruct.new(data_future: data, success?: true),
                               double("ContextDataProvider"), event_handler, event_logger, DefaultVariableParser.new,
                               AudienceMatcher.new(DefaultAudienceDeserializer.new),
                               application: "website", environment: "production")
      context.set_attribute("country", country)
      context
    end

    # [name, variant, assigned, overridden, rule_override]
    def exposures_of(context)
      context.publish
      published.flat_map { |event| event.exposures || [] }.map do |e|
        [e.name, e.variant, e.assigned, e.overridden, e.rule_override]
      end
    end

    def assigned(name, variant = VARIANT)
      [name, variant, true, false, false]
    end

    describe "a lower-id candidate the unit is not in" do
      it "reads from and exposes only the assigned higher-id candidate after a strict audience mismatch" do
        context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(context.pending_count).to eq(1)
        expect(exposures_of(context)).to eq([assigned("exp_high")])
      end

      it "reads from and exposes only the assigned higher-id candidate when its unit type is not set" do
        context = create_context([no_unit(1, "exp_low"), experiment(2, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(context.pending_count).to eq(1)
        expect(exposures_of(context)).to eq([assigned("exp_high")])
      end

      it "orders the candidates by id, not payload order" do
        context = create_context([experiment(2, "exp_high"), strict_mismatch(1, "exp_low")])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_high")])
      end

      it "still exposes the loser through its own treatment call" do
        context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

        context.variable_value("color", "default")
        context.treatment("exp_low")
        expect(exposures_of(context)).to eq([assigned("exp_high"), ["exp_low", 0, false, false, false]])
      end
    end

    describe "a winner whose variant lacks the key" do
      it "returns the default and exposes only the winner, never a later candidate" do
        context = create_context([experiment(1, "exp_low", configs: ['{"color":"control_%d"}', '{"other":"x"}']),
                                  experiment(2, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("default")
        expect(context.pending_count).to eq(1)
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end

      it "returns the default when the winner's variant has no config at all" do
        context = create_context([experiment(1, "exp_low", configs: ['{"color":"control_%d"}', nil]),
                                  experiment(2, "exp_high")])

        expect(context.peek_variable_value("color", "default")).to eq("default")
        expect(context.variable_value("color", "default")).to eq("default")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end
    end

    it "returns the default and queues nothing when no candidate is assigned" do
      context = create_context([strict_mismatch(1, "exp_low"), no_unit(2, "exp_high")])

      expect(context.variable_value("color", "default")).to eq("default")
      expect(context.pending_count).to eq(0)
      expect(exposures_of(context)).to eq([])
    end

    it "returns the default and queues nothing for a key no experiment defines" do
      context = create_context([experiment(1, "exp_low")])

      expect(context.variable_value("missing", "default")).to eq("default")
      expect(context.pending_count).to eq(0)
    end

    it "queues nothing on peek and returns what variable_value returns" do
      context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

      expect(context.peek_variable_value("color", "default")).to eq("treatment_2")
      expect(context.pending_count).to eq(0)
      expect(context.variable_value("color", "default")).to eq("treatment_2")
      expect(context.pending_count).to eq(1)
    end

    it "does not call the holdout path for candidates without holdouts or already exposed" do
      context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high", holdoutIds: [11])],
                               holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])
      context.variable_value("color", "default")

      expect(context).not_to receive(:queue_holdout_exposures)
      3.times { context.variable_value("color", "default") }
    end

    it "queues the winner once across repeated reads" do
      context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

      3.times { context.variable_value("color", "default") }
      expect(exposures_of(context)).to eq([assigned("exp_high")])
    end

    describe "precedence" do
      it "lets an override on a candidate the unit is not in win" do
        context = create_context([strict_mismatch(1, "exp_skipped"), no_unit(2, "exp_low"), experiment(3, "exp_high")],
                                 overrides: { "exp_low" => 0 })

        expect(context.variable_value("color", "default")).to eq("control_2")
        expect(exposures_of(context)).to eq([["exp_low", 0, false, true, false]])
      end

      it "keeps an assigned lower-id candidate ahead of an override on a higher-id one" do
        context = create_context([strict_mismatch(1, "exp_skipped"), experiment(2, "exp_low"),
                                  experiment(3, "exp_high")], overrides: { "exp_high" => 0 })

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end

      it "lets a rule on a strict-mismatch candidate win" do
        context = create_context([strict_mismatch(1, "exp_skipped"),
                                  strict_mismatch(2, "exp_low").merge(assignmentRules: US_RULE.sub("US\"}", "GB\"}")),
                                  experiment(3, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("control_2")
        expect(exposures_of(context)).to eq([["exp_low", 0, false, false, true]])
      end

      it "keeps an assigned lower-id candidate ahead of a rule on a higher-id one" do
        context = create_context([no_unit(1, "exp_skipped"), experiment(2, "exp_low"),
                                  experiment(3, "exp_high", assignmentRules: US_RULE)], country: "US")

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end
    end

    describe "values that are present but falsy" do
      [[nil, "null"], [false, "false"], [0, "0"], ["", '""'], [[], "[]"], [{}, "{}"]].each do |value, json|
        it "returns #{json} from the winner rather than the default" do
          context = create_context([strict_mismatch(1, "exp_low"),
                                    experiment(2, "exp_high", configs: ['{"color":1}', "{\"color\":#{json}}"])])

          expect(context.peek_variable_value("color", "default")).to eq(value)
          expect(context.variable_value("color", "default")).to eq(value)
          expect(exposures_of(context)).to eq([assigned("exp_high")])
        end
      end
    end

    # java-sdk fires the applicable holdouts of every candidate visited on a
    # non-peek read, while only the winner gets its own exposure.
    describe "a refresh that moves the key while a read walks the candidates" do
      # The first candidate (strict mismatch) is covered by a holdout; its
      # holdout exposure is logged mid-walk, and the logger refreshes there.
      # The refresh moves "color" from exp_b to exp_c, so the read must return
      # and expose as one snapshot alone would: blue from exp_b, or green from
      # exp_c, never the default with an exp_b exposure.
      it "returns a value and exposes an experiment from one snapshot" do
        before = [strict_mismatch(1, "exp_a").merge(holdoutIds: [9]),
                  experiment(2, "exp_b", configs: ['{"color":"blue"}', '{"color":"blue"}']),
                  experiment(3, "exp_c", configs: ['{"shade":"green"}', '{"shade":"green"}'])]
        after = [strict_mismatch(1, "exp_a").merge(holdoutIds: [9]),
                 experiment(2, "exp_b", configs: ['{"shade":"blue"}', '{"shade":"blue"}']),
                 experiment(3, "exp_c", configs: ['{"color":"green"}', '{"color":"green"}'])]
        holdouts = [holdout(9, "holdout_a", NOT_HOLDING_OUT)]
        refreshed = JSON.generate(experiments: after, holdouts: holdouts)
        provider = double("ContextDataProvider")
        allow(provider).to receive(:context_data) do
          OpenStruct.new(data_future: DefaultContextDataDeserializer.new.deserialize(refreshed, 0, refreshed.length),
                         success?: true)
        end
        holder = {}
        logger = double("ContextEventLogger")
        allow(logger).to receive(:handle_event) do |type, data|
          if type == ContextEventLogger::EVENT_TYPE::EXPOSURE && data.name == "holdout_a" && !holder[:done]
            holder[:done] = true
            holder[:context].refresh
          end
        end
        payload = JSON.generate(experiments: before, holdouts: holdouts)
        data = DefaultContextDataDeserializer.new.deserialize(payload, 0, payload.length)
        config = ContextConfig.create
        config.set_units(UNIT_TYPE => UID)
        context = Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), provider,
                                 event_handler, logger, DefaultVariableParser.new,
                                 AudienceMatcher.new(DefaultAudienceDeserializer.new),
                                 application: "website", environment: "production")
        context.set_attribute("country", "GB")
        holder[:context] = context

        value = context.variable_value("color", "default")
        exposed = exposures_of(context).map(&:first)
        expect(holder[:done]).to be true
        expect([[value, exposed]]).to include(["blue", %w[holdout_a exp_b]]).or include(["green", %w[holdout_a exp_c]])
      end


      # The refresh lands after the walk has read its candidates and before it
      # resolves the first one: the walk must start again on the new state
      # instead of finishing the old candidate list against new experiments.
      it "resolves every candidate from the snapshot it read them from" do
        before = [experiment(1, "exp_a", audienceStrict: true, audience: US_ONLY),
                  experiment(2, "exp_b", configs: ['{"color":"blue"}', '{"color":"blue"}']),
                  experiment(3, "exp_c", configs: ['{"shade":"green"}', '{"shade":"green"}'])]
        after = [experiment(1, "exp_a", audienceStrict: true, audience: US_ONLY),
                 experiment(2, "exp_b", configs: ['{"shade":"blue"}', '{"shade":"blue"}']),
                 experiment(3, "exp_c", configs: ['{"color":"green"}', '{"color":"green"}'])]
        refreshed = JSON.generate(experiments: after)
        provider = double("ContextDataProvider")
        allow(provider).to receive(:context_data) do
          OpenStruct.new(data_future: DefaultContextDataDeserializer.new.deserialize(refreshed, 0, refreshed.length),
                         success?: true)
        end
        payload = JSON.generate(experiments: before)
        data = DefaultContextDataDeserializer.new.deserialize(payload, 0, payload.length)
        config = ContextConfig.create
        config.set_units(UNIT_TYPE => UID)
        context = Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), provider,
                                 event_handler, event_logger, DefaultVariableParser.new,
                                 AudienceMatcher.new(DefaultAudienceDeserializer.new),
                                 application: "website", environment: "production")
        context.set_attribute("country", "GB")
        refreshed_once = false
        allow(context).to receive(:assignment).and_wrap_original do |original, name|
          unless refreshed_once
            refreshed_once = true
            context.refresh
          end
          original.call(name)
        end

        value = context.variable_value("color", "default")
        expect(refreshed_once).to be true
        expect([[value, exposures_of(context).map(&:first)]]).to include(["blue", ["exp_b"]])
          .or include(["green", ["exp_c"]])
      end

      # A peek walks the same candidates and exposes nothing; the refresh
      # lands from the audience matcher evaluating the first candidate.
      it "peeks a value from one snapshot" do
        before = [strict_mismatch(1, "exp_a"),
                  experiment(2, "exp_b", configs: ['{"color":"blue"}', '{"color":"blue"}']),
                  experiment(3, "exp_c", configs: ['{"shade":"green"}', '{"shade":"green"}'])]
        after = [strict_mismatch(1, "exp_a"),
                 experiment(2, "exp_b", configs: ['{"shade":"blue"}', '{"shade":"blue"}']),
                 experiment(3, "exp_c", configs: ['{"color":"green"}', '{"color":"green"}'])]
        refreshed = JSON.generate(experiments: after)
        provider = double("ContextDataProvider")
        allow(provider).to receive(:context_data) do
          OpenStruct.new(data_future: DefaultContextDataDeserializer.new.deserialize(refreshed, 0, refreshed.length),
                         success?: true)
        end
        holder = {}
        matcher = AudienceMatcher.new(DefaultAudienceDeserializer.new)
        evaluate = matcher.method(:evaluate)
        matcher.define_singleton_method(:evaluate) do |audience, attributes|
          result = evaluate.call(audience, attributes)
          if holder[:armed] && !holder[:done]
            holder[:done] = true
            holder[:context].refresh
          end
          result
        end
        payload = JSON.generate(experiments: before)
        data = DefaultContextDataDeserializer.new.deserialize(payload, 0, payload.length)
        config = ContextConfig.create
        config.set_units(UNIT_TYPE => UID)
        context = Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), provider,
                                 event_handler, event_logger, DefaultVariableParser.new, matcher,
                                 application: "website", environment: "production")
        context.set_attribute("country", "GB")
        holder[:context] = context
        holder[:armed] = true

        expect(%w[blue green]).to include(context.peek_variable_value("color", "default"))
        expect(holder[:done]).to be true
        expect(context.pending_count).to eq(0)
      end

      # Round 33 replay: the refresh lands from the audience matcher while the
      # walk evaluates exp_a, and also gives exp_b a holdout of its own. The
      # walk is discarded before anything is exposed, so b_only, which no
      # standing walk visits, is never exposed.
      it "exposes no holdout of a candidate visited only by a discarded walk" do
        holdouts_before = [holdout(9, "holdout_a", NOT_HOLDING_OUT)]
        before = [strict_mismatch(1, "exp_a").merge(holdoutIds: [9]),
                  experiment(2, "exp_b", configs: ['{"color":"blue"}', '{"color":"blue"}']),
                  experiment(3, "exp_c", configs: ['{"shade":"green"}', '{"shade":"green"}'])]
        after = [strict_mismatch(1, "exp_a").merge(holdoutIds: [9]),
                 experiment(2, "exp_b", configs: ['{"shade":"blue"}', '{"shade":"blue"}'], holdoutIds: [8]),
                 experiment(3, "exp_c", configs: ['{"color":"green"}', '{"color":"green"}'])]
        holdouts_after = [holdout(8, "b_only", NOT_HOLDING_OUT), holdout(9, "holdout_a", NOT_HOLDING_OUT)]
        refreshed = JSON.generate(experiments: after, holdouts: holdouts_after)
        provider = double("ContextDataProvider")
        allow(provider).to receive(:context_data) do
          OpenStruct.new(data_future: DefaultContextDataDeserializer.new.deserialize(refreshed, 0, refreshed.length),
                         success?: true)
        end
        holder = {}
        matcher = AudienceMatcher.new(DefaultAudienceDeserializer.new)
        evaluate = matcher.method(:evaluate)
        matcher.define_singleton_method(:evaluate) do |audience, attributes|
          result = evaluate.call(audience, attributes)
          if holder[:armed] && !holder[:done]
            holder[:done] = true
            holder[:context].refresh
          end
          result
        end
        payload = JSON.generate(experiments: before, holdouts: holdouts_before)
        data = DefaultContextDataDeserializer.new.deserialize(payload, 0, payload.length)
        config = ContextConfig.create
        config.set_units(UNIT_TYPE => UID)
        context = Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), provider,
                                 event_handler, event_logger, DefaultVariableParser.new, matcher,
                                 application: "website", environment: "production")
        context.set_attribute("country", "GB")
        holder[:context] = context
        holder[:armed] = true

        value = context.variable_value("color", "default")
        expect(holder[:done]).to be true
        expect([[value, exposures_of(context).map(&:first)]]).to include(["green", %w[holdout_a exp_c]])
      end

      # A matcher that refreshes on every evaluation, with data alternating so
      # every walk is overtaken: the read stops after three attempts, returns
      # the default and exposes nothing, rather than refetching forever.
      %i[variable_value peek_variable_value].each do |read|
        it "#{read} stops after three walks a refresh overtook" do
          # Each refresh bumps exp_a's iteration, so every walk resolves it (and
          # evaluates its audience) again.
          snapshot = lambda do |owner, iteration|
            json = JSON.generate(holdouts: [holdout(9, "holdout_a", NOT_HOLDING_OUT)], experiments: [
              strict_mismatch(1, "exp_a").merge(holdoutIds: [9], iteration: iteration),
              experiment(2, "exp_b", configs: [owner == :b ? '{"color":"blue"}' : '{"shade":"blue"}'] * 2),
              experiment(3, "exp_c", configs: [owner == :c ? '{"color":"green"}' : '{"shade":"green"}'] * 2)
            ])
            DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
          end
          # exp_b keeps the key: a walk that returned its last overtaken winner
          # would give blue, so only the exhaustion default passes.
          owners = %i[b b].cycle
          refreshes = 0
          provider = double("ContextDataProvider")
          allow(provider).to receive(:context_data) do
            refreshes += 1
            OpenStruct.new(data_future: snapshot.call(owners.next, refreshes + 1), success?: true)
          end
          holder = {}
          matcher = AudienceMatcher.new(DefaultAudienceDeserializer.new)
          evaluate = matcher.method(:evaluate)
          matcher.define_singleton_method(:evaluate) do |audience, attributes|
            result = evaluate.call(audience, attributes)
            if holder[:armed]
              raise "no progress after #{refreshes} refreshes" if refreshes > 10

              holder[:context].refresh
            end
            result
          end
          config = ContextConfig.create
          config.set_units(UNIT_TYPE => UID)
          context = Context.create(clock, config, OpenStruct.new(data_future: snapshot.call(:b, 1), success?: true),
                                   provider, event_handler, event_logger, DefaultVariableParser.new, matcher,
                                   application: "website", environment: "production")
          context.set_attribute("country", "GB")
          holder[:context] = context
          holder[:armed] = true

          expect(context.public_send(read, "color", "default")).to eq("default")
          expect(refreshes).to eq(3)
          holder[:armed] = false
          expect(exposures_of(context)).to eq([])
        end
      end

      # Two reads on one context, interleaved outside the locks: a
      # variable_value collects exp_low's holdout and pauses before resolving
      # exp_high, while a peek on another key runs whole (peek first), or the
      # variable read finishes while the peek is paused (variable first).
      # Each read's collected holdouts are its own: the variable read exposes
      # its holdout before its winner, and the peek exposes nothing.
      %i[peek_first variable_first].each do |order|
        it "keeps each concurrent read's collected holdouts its own (#{order.to_s.tr("_", " ")})" do
          # "size" is shared too, so the peek walks (and collects) as well.
          experiments = [strict_mismatch(1, "exp_low").merge(holdoutIds: [11]),
                         experiment(2, "exp_high"),
                         experiment(3, "exp_size", configs: ['{"size":1}', '{"size":2}']),
                         experiment(4, "exp_size_too", configs: ['{"size":3}', '{"size":4}'])]
          context = create_context(experiments, holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])
          gates = { variable: [Queue.new, Queue.new], peek: [Queue.new, Queue.new] }
          pause_at = { variable: "exp_high", peek: "exp_size" }
          allow(context).to receive(:assignment).and_wrap_original do |original, name|
            role = Thread.current[:role]
            if role && name.to_s == pause_at[role] && !Thread.current[:paused]
              Thread.current[:paused] = true
              gates[role][0] << true
              gates[role][1].pop
            end
            original.call(name)
          end
          read = Thread.new do
            Thread.current[:role] = :variable
            context.variable_value("color", "default")
          end
          peek = Thread.new do
            Thread.current[:role] = :peek
            context.peek_variable_value("size", 0)
          end
          pending_after_peek = nil
          begin
            Timeout.timeout(5) { gates[:variable][0].pop }
            Timeout.timeout(5) { gates[:peek][0].pop }
            if order == :peek_first
              gates[:peek][1] << true
              Timeout.timeout(5) { peek.join }
              pending_after_peek = context.pending_count
              gates[:variable][1] << true
            else
              gates[:variable][1] << true
              Timeout.timeout(5) { read.join }
              pending_after_peek = context.pending_count - 2
              gates[:peek][1] << true
            end
            Timeout.timeout(5) { [read, peek].each(&:join) }
          ensure
            gates.each_value { |(_, go)| go << true }
            [read, peek].each { |t| t.join(1) || t.kill }
          end

          expect(peek.value).to eq(2)
          expect(read.value).to eq("treatment_2")
          expect(pending_after_peek).to eq(0)
          expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("exp_high")])
        end
      end
    end

    describe "holdouts" do
      it "exposes a visited loser's holdout but not the loser itself" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("exp_high")])
      end

      it "does not expose the holdouts of candidates after the winner" do
        context = create_context([no_unit(1, "exp_skipped"), experiment(2, "exp_low"),
                                  experiment(3, "exp_high", holdoutIds: [11])],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end

      it "reads a held-out candidate's control only when no candidate is assigned" do
        context = create_context([experiment(1, "exp_low", holdoutIds: [11]), strict_mismatch(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("control_1")
        expect(exposures_of(context)).to eq([["holdout_a", 0, true, false, false]])
      end

      it "exposes a visited loser's holdout once across repeated reads" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        3.times { expect(context.variable_value("color", "default")).to eq("treatment_2") }
        expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("exp_high")])
      end

      it "exposes only a loser's still-unexposed holdout when another is already exposed" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11, 12]), experiment(2, "exp_high"),
                                  experiment(5, "exp_other", configs: ['{"size":1}', '{"size":2}'], holdoutIds: [11])],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT),
                                            holdout(12, "holdout_b", NOT_HOLDING_OUT)])
        context.treatment("exp_other")

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_other"), assigned("holdout_a"), assigned("holdout_b"),
                                             assigned("exp_high")])
      end

      it "queues the winner's holdouts before the winner, as java-sdk does" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]),
                                  experiment(2, "exp_high", holdoutIds: [12])],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT),
                                            holdout(12, "holdout_b", NOT_HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("holdout_b"), assigned("exp_high")])
      end

      it "stamps a loser's holdout exposure with the read's clock" do
        ticks = (1000..).step(1000).each
        allow(clock).to receive(:to_i) { ticks.next }
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        context.variable_value("color", "default")
        context.publish
        expect(published.flat_map(&:exposures).map { |e| [e.name, e.exposed_at] }).to eq([["holdout_a", 2000],
                                                                                          ["exp_high", 3000]])
      end

      it "reads the clock only for the first exposures, not on warm reads past a covered loser" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])
        context.variable_value("color", "default")

        expect(clock).not_to receive(:to_i)
        3.times { context.variable_value("color", "default") }
      end

      it "queues no loser holdout exposure once a logger callback closed the context" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]),
                                  strict_mismatch(2, "exp_mid").merge(holdoutIds: [12]), experiment(3, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT),
                                            holdout(12, "holdout_b", NOT_HOLDING_OUT)])
        allow(event_logger).to receive(:handle_event) do |_type, data|
          context.close if data.is_a?(Exposure) && data.name == "holdout_a"
        end

        expect { context.variable_value("color", "default") }.to raise_error(IllegalStateException, /closed/)
        # close published what was queued before it; nothing was queued after.
        expect(published.flat_map(&:exposures).map(&:name)).to eq(["holdout_a"])
        expect(context.pending_count).to eq(0)
      end

      it "fires nothing on peek" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        expect(context.peek_variable_value("color", "default")).to eq("treatment_2")
        expect(context.pending_count).to eq(0)
      end
    end
  end
end
