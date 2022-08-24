# frozen_string_literal: true

require "arraybuffer"
require "murmurhash3"
require "digest/md5"

module Absmartly
  # VariantAssigner
  class VariantAssigner
    include MurmurHash3::V32

    def initialize(_unit)
      @unit_hash = murmur3_32_str_hash(hash_unit(_unit))
    end

    def hash_unit(value)
      value.is_a?(String) ? value : value.round(0)
      base64 = Digest::MD5.base64digest(value)

      base64 = base64.include?("+") ? base64.gsub!("+", "-") : base64
      base64 = base64.include?("/") ? base64.gsub!("/", "_") : base64
      base_64_url_no_padding(base64)
    end

    def assign(split, seed_hi, seed_lo)
      prob = probability(seed_hi, seed_lo)
      chooseVariant(split, prob)
    end

    def base_64_url_no_padding(base64)
      padding = true
      while padding == true
        base64[-1] == "=" ? base64 = base64.chop : padding = false
      end

      base64url = base64
    end

    # converting string to byte
    def string_to_uint8_array(value)
      n     = value.length
      array = ArrayBuffer.new(value.length)

      k = 0
      (0..n - 1).each do |index|
        c = value[index].ord

        if c < 0x80
          array[k] = c
          k        += 1
        elsif c < 0x800
          array[k] = (c >> 6) | 192
          k        += 1
          array[k] = (c & 63) | 128
          k        += 1
        else
          array[k] = (c >> 12) | 224
          k        += 1
          array[k] = ((c >> 6) & 63) | 128
          k        += 1
          array[k] = (c & 63) | 128
          k        += 1
        end
      end

      array
    end

    # private

    # def chooseVariant(split, prob)
    #
    # end
    #
    def put_uint32(buffer, x)
      buffer << (x & 0xff)
      buffer << ((x >> 8) & 0xff)
      buffer << ((x >> 16) & 0xff)
      buffer << ((x >> 24) & 0xff)
    end


    def probability(seed_hi, seed_lo)
      bytes = Array.new
      key   = @unit_hash

      put_uint32(bytes, seed_lo)
      put_uint32(bytes, seed_hi)
      put_uint32(bytes, key)

      bits_array = bytes.map do |num|
        num = num.to_s(2)

        if num.length < 8
          length  = num.length
          missing = 8 - length
          missing.times do
            num = "0" + num
          end
        end

        num
      end

      murmur3_32_str_hash(bits_array.join().to_i(2))
    end
  end
end


C1 = 0xcc9e2d51
C2 = 0x1b873593
C3 = 0xe6546b64


def rotl32(a, b)
  (a << b) | (a >> (32 - b))
end

def scramble32(block)
  (rotl32((block * C1), 15) * C2)
end

def fmix32(h)
  h ^= h >> 16
  h = h * 0x85ebca6b
  h ^= h >> 13
  h = h * 0xc2b2ae35
  h ^= h >> 16

  h >> 0
end

def murmurs3_32(array, hash)
  hash = (hash || 0) >> 0
  n    = array.length & ~3

  (0..n - 1).step(4).each do |i|
    chunk = array[i]
    hash  ^= scramble32(chunk)
    hash  = rotl32(hash, 13)
    hash  = hash * 5 + C3
  end

  remaining = 0
  case (array.length & 3)
  when 3
    remaining ^= array[i + 2] << 16
  when 2
    remaining ^= array[i + 1] << 8
  when 1
    remaining ^= array[i]
    hash      ^= scramble32(remaining)
  end

  hash ^= array.length
  hash = fmix32(hash)
  hash >> 0
end
