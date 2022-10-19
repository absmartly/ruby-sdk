# frozen_string_literal: true

require "variant_assigner"

RSpec.describe VariantAssigner do
  describe ".choose_variant" do
    probs = [
      0.0,
      0.5,
      1.0,
      0.0,
      0.5,
      1.0,
      0.0,
      0.25,
      0.49999999,
      0.5,
      0.50000001,
      0.75,
      1.0,
      0.0,
      0.25,
      0.33299999,
      0.333,
      0.33300001,
      0.5,
      0.66599999,
      0.666,
      0.66600001,
      0.75,
      1.0,
      0.0,
      1.0
    ]

    splits = [
      [0.0, 1.0],
      [0.0, 1.0],
      [0.0, 1.0],
      [1.0, 0.0],
      [1.0, 0.0],
      [1.0, 0.0],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.333, 0.333, 0.334],
      [0.0, 1.0],
      [0.0, 1.0]
    ]

    variants = [1, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1]

    splits.each_with_index do |split, i|
      it "with split:#{split}, prob:#{probs[i]}" do
        expect(VariantAssigner.choose_variant(split, probs[i])).to eq variants[i]
      end
    end
  end

  describe "#assign" do
    splits = [
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.5, 0.5],
      [0.33, 0.33, 0.34],
      [0.33, 0.33, 0.34],
      [0.33, 0.33, 0.34],
      [0.33, 0.33, 0.34],
      [0.33, 0.33, 0.34],
      [0.33, 0.33, 0.34],
      [0.33, 0.33, 0.34]
    ]

    seeds = [
      [0x00000000, 0x00000000],
      [0x00000000, 0x00000001],
      [0x8015406f, 0x7ef49b98],
      [0x3b2e7d90, 0xca87df4d],
      [0x52c1f657, 0xd248bb2e],
      [0x865a84d0, 0xaa22d41a],
      [0x27d1dc86, 0x845461b9],
      [0x00000000, 0x00000000],
      [0x00000000, 0x00000001],
      [0x8015406f, 0x7ef49b98],
      [0x3b2e7d90, 0xca87df4d],
      [0x52c1f657, 0xd248bb2e],
      [0x865a84d0, 0xaa22d41a],
      [0x27d1dc86, 0x845461b9]
    ]

    keys_with_variants = {
      123_456_789 => [1, 0, 1, 1, 1, 0, 0, 2, 1, 2, 2, 2, 0, 0],
      "bleh@absmartly.com" => [0, 1, 0, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 1],
      "e791e240fcd3df7d238cfc285f475e8152fcc0ec" => [1, 0, 1, 1, 0, 0, 0, 2, 0, 2, 1, 0, 0, 1]
    }

    keys_with_variants.each do |key, variants|
      splits.each_with_index do |split, i|
        it "with key:#{key}, split: #{split}, seeds[]:#{seeds[i]}, variant:#{variants[i]}" do
          @variant_assigner = VariantAssigner.new(key)
          seed_hi, seed_lo = seeds[i]
          expect(@variant_assigner.assign(split, seed_hi, seed_lo)).to eq variants[i]
        end
      end
    end
  end
end
