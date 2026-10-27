# frozen_string_literal: true

require "hashing"
require "murmurhash3"

RSpec.describe Hashing do
  describe ".hash_unit" do
    tests = [
       ["", "1B2M2Y8AsgTpgAmY7PhCfg"],
       [" ", "chXunH2dwinSkhpA6JnsXw"],
       ["t", "41jvpIn1gGLxDdcxa2Vkng"],
       ["te", "Vp73JkK-D63XEdakaNaO4Q"],
       ["tes", "KLZi2IO212_Zbk3cXpungA"],
       ["test", "CY9rzUYh03PK3k6DJie09g"],
       ["testy", "K5I_V6RgP8c6sYKz-TVn8g"],
       ["testy1", "8fT8xGipOhPkZ2DncKU-1A"],
       ["testy12", "YqRAtOz000gIu61ErEH18A"],
       ["testy123", "pfV2H07L6WvdqlY0zHuYIw"],
       ["special characters açb↓c", "4PIrO7lKtTxOcj2eMYlG7A"],
       # Characters outside the BMP are stored as UTF-16 surrogate pairs and must
       # encode to 4-byte UTF-8; these canonical hashes are shared across all SDKs.
       ["😀", "KgLqw51xanDs83V5GFkntg"],
       ["😀😁", "ZJuDalvUWRJnVtkspj-2bQ"],
       ["世界你好", "v2CJG7YcjjWncKOSCzF2GA"],
       ["user_世界_123", "SCgk4OzXlFMvo1UMsP88fA"],
       ["The quick brown fox jumps over the lazy dog", "nhB9nTcrtoJr2B01QqQZ1g"],
       ["The quick brown fox jumps over the lazy dog and eats a pie", "iM-8ECRrLUQzixl436y96A"],
       ["Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
             "24m7XOq4f5wPzCqzbBicLA"]
    ]

    tests.each do |test|
      it "given: #{test.first}, then: md5 must be #{test.last}" do
        md5 = Hashing.hash_unit(test.first)
        expect(md5).to eq(test.last)
      end
    end

    it "hashes numbers as their value rounded to an integer" do
      expect(Hashing.hash_unit(12345)).to eq("gnzLDuqKcGxMNKFokfhOew")
      expect(Hashing.hash_unit(125)).to eq("Pe8YStj0dV_yaYYup3OT3Q")
      expect(Hashing.hash_unit(125.75)).to eq("BpBZt--EDwx0qBTskje27A")
    end

    it "formats numbers like JavaScript toFixed(0)" do
      expect(Hashing.hash_unit(-0.1)).to eq("815ubasUW2p7sFI440lKaw")
      expect(Hashing.hash_unit(1e21)).to eq("OKkjo8sn5USSUjdjCUBynw")
      { -0.1 => "-0", -0.0 => "0", -2.5 => "-3", 2.5 => "3", 1e21 => "1e+21", 1.5e22 => "1.5e+22",
        1e20 => "100000000000000000000", 2**60 + 1 => "1152921504606846976" }.each do |num, text|
        expect(Hashing.number_to_fixed0(num)).to eq(text)
      end
    end
  end

  describe ".base64_url_no_padding" do
    it "encodes url-safe without padding" do
      expect(Hashing.base64_url_no_padding("")).to eq("")
      expect(Hashing.base64_url_no_padding("\xfb\xff".b)).to eq("-_8")
      expect(Hashing.base64_url_no_padding("a")).to eq("YQ")
    end
  end
end

RSpec.describe TypeUtils do
  require "type_utils"
  it "object? is true only for hashes" do
    expect(TypeUtils.object?({})).to be true
    expect([[], 1, "s", nil].map { |v| TypeUtils.object?(v) }).to all(be false)
  end

  it "numeric? is true only for numbers" do
    expect([1, 1.5].map { |v| TypeUtils.numeric?(v) }).to all(be true)
    expect(["1", true, {}, nil].map { |v| TypeUtils.numeric?(v) }).to all(be false)
  end
end

RSpec.describe "Murmur3_32" do
  describe "should match known hashes" do
    murmur3_tests = [
      ["", 0x00000000, 0],
      [" ", 0x00000000, 2129959832],
      ["t", 0x00000000, 3397902157],
      ["te", 0x00000000, 3988319771],
      ["tes", 0x00000000, 196677210],
      ["test", 0x00000000, 3127628307],
      ["testy", 0x00000000, 1152353090],
      ["testy1", 0x00000000, 2316969018],
      ["testy12", 0x00000000, 2220122553],
      ["testy123", 0x00000000, 1197640388],
      ["special characters açb↓c", 0x00000000, 3196301632],
      ["The quick brown fox jumps over the lazy dog", 0x00000000, 776992547],
      ["", 0xdeadbeef, 233162409],
      [" ", 0xdeadbeef, 632081987],
      ["t", 0xdeadbeef, 991288568],
      ["te", 0xdeadbeef, 2895647538],
      ["tes", 0xdeadbeef, 3251080666],
      ["test", 0xdeadbeef, 2854409242],
      ["testy", 0xdeadbeef, 2230711843],
      ["testy1", 0xdeadbeef, 166537449],
      ["testy12", 0xdeadbeef, 575043637],
      ["testy123", 0xdeadbeef, 3593668109],
      ["special characters açb↓c", 0xdeadbeef, 4160608418],
      ["The quick brown fox jumps over the lazy dog", 0xdeadbeef, 981155661],
      ["", 0x00000001, 1364076727],
      [" ", 0x00000001, 1326412082],
      ["t", 0x00000001, 1571914526],
      ["te", 0x00000001, 3527981870],
      ["tes", 0x00000001, 3560106868],
      ["test", 0x00000001, 2579507938],
      ["testy", 0x00000001, 3316833310],
      ["testy1", 0x00000001, 865230059],
      ["testy12", 0x00000001, 3643580195],
      ["testy123", 0x00000001, 1002533165],
      ["special characters açb↓c", 0x00000001, 691218357],
      ["The quick brown fox jumps over the lazy dog", 0x00000001, 2028379687]
    ]

    murmur3_tests.each do |input, seed, expected_hash|
      it "hashes '#{input}' with seed 0x#{seed.to_s(16).rjust(8, '0')} to #{expected_hash}" do
        result = MurmurHash3::V32.str_hash(input, seed)
        expect(result).to eq(expected_hash)
      end
    end
  end
end
