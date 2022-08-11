# frozen_string_literal: true

require "arraybuffer"
require "murmurhash3"

module Absmartly
  # VariantAssigner
  class VariantAssigner
    def initialize(_unit)
      # this._unitHash = murmur3_32(stringToUint8Array(unit).buffer);
    end

    def assign(split, seed_hi, seed_lo)
      prob = probability(seed_hi, seed_lo)
      chooseVariant(split, prob)
    end

    # private

    # def chooseVariant(split, prob)
    #
    # end
    #
    # def probability(seedHi, seedLo)
    #   const key = this._unitHash;
    #   const buffer = new ArrayBuffer(12)
    #   const view = new DataView(buffer)
    #   view.setUint32(0, seedLo, true)
    #   view.setUint32(4, seedHi, true)
    #   view.setUint32(8, key, true)
    #
    #   murmur3_32(buffer) * (1.0 / 0xffffffff)
    # end
  end
end
# DataView.new(new_bytes_buffer, src_offset, new_bytes.length)
