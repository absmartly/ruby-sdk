# frozen_string_literal: true

require "json"
require "murmurhash3"

module Absmartly
  # Switchback serving, ported from java-sdk (SWITCHBACK.md and
  # internal/Switchback*.java), which ports the Collector. Internal: nothing
  # here is public API.
  module Switchback
    # Balanced-block switchback assignment. Port of the platform's
    # SwitchbackAssignment (murmur3_32, seed 0):
    #   key       = utf8(cluster_unit + "\u001f" + cycle_index)
    #   base_hash = murmur3_32(le64(seed) ++ le32(murmur3_32(key)))
    #   step_hash = murmur3_32(le32(base_hash) ++ le32(i)),  i = arm_count-1 .. 1
    #   j         = min(i, floor(u32(step_hash) / 0xffffffff * (i + 1)))
    #   variant   = permutation[period_index mod arm_count], cycle = floor(period_index / arm_count)
    # Integers are exact here, so floor division needs no care at the 64-bit
    # bounds; the seed is the signed 64-bit (seedHi << 32) | (seedLo & 0xffffffff).
    # Any change breaks parity with the platform golden vectors.
    module Assigner
      NORMALIZER = 1.0 / 0xffffffff
      SEPARATOR = "\u001f"

      def self.assign(cluster_unit, period_index, seed, arm_count)
        require_valid_arm_count(arm_count)
        cycle_index = period_index.div(arm_count)
        fisher_yates_permutation(arm_count, base_hash(cluster_unit, cycle_index, seed))[period_index % arm_count]
      end

      def self.base_hash(cluster_unit, cycle_index, seed)
        key = "#{cluster_unit}#{SEPARATOR}#{cycle_index}".encode(Encoding::UTF_8).b
        key_hash = MurmurHash3::V32.str_hash(key)
        MurmurHash3::V32.str_hash([seed & 0xffffffff, (seed >> 32) & 0xffffffff, key_hash].pack("V3"))
      end

      def self.fisher_yates_permutation(arm_count, base_hash)
        require_valid_arm_count(arm_count)
        permutation = (0...arm_count).to_a
        (arm_count - 1).downto(1) do |i|
          step_hash = MurmurHash3::V32.str_hash([base_hash, i].pack("V2"))
          # prob == 1.0 would map to i + 1
          j = [i, ((step_hash & 0xffffffff) * NORMALIZER * (i + 1)).floor].min
          permutation[i], permutation[j] = permutation[j], permutation[i]
        end
        permutation
      end

      def self.require_valid_arm_count(arm_count)
        raise ArgumentError, "arm_count must be >= 2, got #{arm_count}" unless arm_count.is_a?(Integer) && arm_count >= 2
      end
    end

    # The cluster key an attribute value yields, as the Collector's
    # SwitchbackClusterKeys.normalize: a non-empty String as-is, an Integer as
    # its base-10 text. nil, "", booleans, every Float (3.0 included), objects
    # and arrays yield none. The key is passed to Assigner unhashed.
    module ClusterKeys
      def self.normalize(value)
        case value
        when String then value.empty? ? nil : value
        when Integer then value.to_s
        end
      end
    end

    # A cluster attribute path, resolved like the Collector's
    # SwitchbackAttributePath: "/" separates segments, a segment wrapped in '
    # or " is a literal key, and an unquoted segment that Guava Ints.tryParse
    # accepts (ASCII digits, optional leading '-', in int range) indexes an
    # Array and nothing else. Every other segment reads a Hash key. A path is
    # malformed when a quote is unterminated or it contains a '.' anywhere
    # (dotted paths are not a nesting syntax).
    class AttributePath
      MAX_DEPTH = 64
      INT_MIN = -(2**31)
      INT_MAX = (2**31) - 1

      attr_reader :keys, :indices

      def initialize(keys, indices)
        @keys = keys.freeze
        @indices = indices.freeze
        freeze
      end

      # nil for an unsupported path: not a String, malformed, empty, or an
      # index that is negative, first, last or directly after another index.
      def self.parse_supported(path)
        return nil unless path.is_a?(String)

        parsed = parse(path)
        return nil if parsed.nil? || parsed.keys.empty?

        n = parsed.keys.length
        parsed.indices.each_with_index do |index, i|
          next if index.nil?
          return nil if index.negative? || i.zero? || i == n - 1 || !parsed.indices[i - 1].nil?
        end
        parsed
      end

      def self.parse(path)
        return nil if path.include?(".")

        keys = []
        indices = []
        i = 0
        while i < path.length
          if path[i] == "/"
            i += 1
            next
          end

          first = path[i]
          if first == "'" || first == '"'
            stop = path.index(first, i + 1)
            return nil if stop.nil?

            keys << path[(i + 1)...stop]
            indices << nil
            i = stop + 1
          else
            stop = path.index("/", i) || path.length
            key = path[i...stop]
            keys << key
            indices << try_parse_int(key)
            i = stop
          end
        end
        new(keys, indices)
      end

      # Guava Ints.tryParse: optional '-', then one or more ASCII digits, in
      # int range; otherwise nil. "+1" and non-ASCII digits are not numbers.
      def self.try_parse_int(text)
        return nil unless text.match?(/\A-?[0-9]+\z/)

        value = Integer(text, 10)
        value.between?(INT_MIN, INT_MAX) ? value : nil
      end

      # The attribute name the path starts at.
      def root_key
        keys[0]
      end

      def resolve(attributes)
        resolve_from(attributes, 0)
      end

      # Resolves the path below root_key in an attribute value, read as the
      # Collector reads it: the value's JSON encoding, as published, decoded
      # back. nil when the value has no JSON encoding, or contains a cycle or
      # nests deeper than MAX_DEPTH.
      def resolve_attribute(root_value)
        return nil if root_value.nil?

        decoded = case root_value
                  when String, Integer, true, false then root_value
                  else
                    return nil unless acyclic_within_depth?(root_value, {}.compare_by_identity, 0)

                    begin
                      JSON.parse([root_value].to_json)[0]
                    rescue StandardError
                      return nil
                    end
        end
        resolve_from(decoded, 1)
      end

      private
        def acyclic_within_depth?(value, path, depth)
          children = case value
                     when Hash then value.values
                     when Array then value
                     else return true
          end
          return false if depth >= MAX_DEPTH || path.key?(value)

          path[value] = true
          return false unless children.all? { |child| acyclic_within_depth?(child, path, depth + 1) }

          path.delete(value)
          true
        end

        def resolve_from(root, first)
          current = root
          (first...keys.length).each do |i|
            current = step(current, keys[i], indices[i])
            return nil if current.nil?
          end
          current
        end

        def step(current, key, index)
          if !index.nil?
            current.is_a?(Array) && index >= 0 && index < current.length ? current[index] : nil
          elsif current.is_a?(Hash)
            current[key]
          end
        end
    end

    # Which unit serves a switchback and under which cluster key. Port of the
    # Collector's ContextAPI.switchbackServing (R33):
    # - the switchbackClusters map, in declared order, lists the linked unit
    #   types and the attribute path holding each one's cluster value;
    # - no context unit of a linked type: the experiment does not apply (ABSENT);
    # - otherwise each linked unit, in source order, reads the attribute at its
    #   source's path. The first with a value serves, and the value is the
    #   cluster key; units without a value are skipped;
    # - INELIGIBLE, under the first linked unit: no value, two units disagree,
    #   or the allow-list is set and lacks the key;
    # - ELIGIBLE otherwise.
    # A missing, empty or unreadable map takes the legacy path instead.
    class Serving
      ABSENT = 0
      INELIGIBLE = 1
      ELIGIBLE = 2

      # unit_type is the serving unit when ELIGIBLE, the first linked unit when
      # INELIGIBLE, nil when ABSENT. cluster_key is the raw key when ELIGIBLE.
      attr_reader :status, :unit_type, :uid, :cluster_key

      def initialize(status, unit_type = nil, uid = nil, cluster_key = nil)
        @status = status
        @unit_type = unit_type
        @uid = uid
        @cluster_key = cluster_key
        freeze
      end

      # units maps a unit type (String) to its uid; the context holds at most
      # one uid per type, so the declared source order alone decides which
      # unit serves. read returns the raw value at a path, or nil.
      def self.resolve(source_types, source_paths, allowed_values, units)
        first = nil
        serving = nil
        key = nil
        disagreement = false
        source_types.each_with_index do |type, s|
          uid = units[type]
          next if uid.nil?

          first ||= [type, uid]
          value = ClusterKeys.normalize(yield(source_paths[s]))
          next if value.nil?

          if key.nil?
            key = value
            serving = [type, uid]
          elsif key != value
            disagreement = true
          end
        end

        return new(ABSENT) if first.nil?
        return new(INELIGIBLE, *first) if key.nil? || disagreement || !allowed?(allowed_values, key)

        new(ELIGIBLE, serving[0], serving[1], key)
      end

      # The Collector's path for a missing, empty or unreadable cluster map:
      # a unit of the declared unitType only identifies an ineligible control;
      # without one the experiment does not apply.
      def self.legacy(unit_type, units)
        uid = unit_type.nil? ? nil : units[unit_type.to_s]
        uid.nil? ? new(ABSENT) : new(INELIGIBLE, unit_type.to_s, uid)
      end

      # nil or [] admits every value, as in the Collector. Any other non-Array
      # admits none. A scalar entry matches its JSON text, as Jackson coerces
      # it into the Java SDK's String[] (17 as "17", true as "true", 1.5 as
      # "1.5"); an object or array entry matches nothing.
      def self.allowed?(allowed_values, key)
        return true if allowed_values.nil? || (allowed_values.is_a?(Array) && allowed_values.empty?)
        return false unless allowed_values.is_a?(Array)

        allowed_values.any? { |allowed| allowed_text(allowed) == key }
      end

      def self.allowed_text(allowed)
        case allowed
        when String then allowed
        when Integer, true, false then allowed.to_s
        when Float then allowed.finite? ? allowed.to_s : nil
        end
      end

      # The linked unit types of a cluster map, in declared order; nil for a
      # missing, empty or non-Hash map.
      def self.source_types(clusters)
        return nil unless clusters.is_a?(Hash) && !clusters.empty?

        clusters.keys.map(&:to_s)
      end

      # The parsed paths, parallel to source_types; nil when the map is
      # missing, empty, not a Hash, or any path is unsupported.
      def self.source_paths(clusters)
        return nil unless clusters.is_a?(Hash) && !clusters.empty?

        paths = clusters.values.map { |path| AttributePath.parse_supported(path) }
        paths.include?(nil) ? nil : paths
      end
    end
  end
end
