# frozen_string_literal: true

require "murmurhash3"
require_relative "./hashing"

class VariantAssigner
  attr_reader :key

  def initialize(key)
    md5 = Hashing.hash_unit(key.to_s)
    @key = MurmurHash3::V32.str_hash(md5)
    @normalizer = 1.0 / 0xffffffff
  end

  def probability(seed_hi, seed_lo)
    buffer = Array.new
    put_uint32(buffer, seed_lo)
    put_uint32(buffer, seed_hi)
    put_uint32(buffer, key)
    hash = MurmurHash3::V32.str_hash(buffer.pack("C*"))

    prob = (hash & 0xffffffff) * @normalizer
    prob
  end

  def self.choose_variant(split, prob)
    sum = 0
    split.each_with_index do |s, i|
      sum += s
      return i if prob < sum
    end

    split.count - 1
  end

  def assign(split, seed_hi, seed_lo)
    prob = probability(seed_hi, seed_lo)
    self.class.choose_variant(split, prob)
  end

  def put_uint32(buffer, x)
    buffer << (x & 0xff)
    buffer << ((x >> 8) & 0xff)
    buffer << ((x >> 16) & 0xff)
    buffer << ((x >> 24) & 0xff)
  end
end
