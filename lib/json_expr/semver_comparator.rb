# frozen_string_literal: true

# A port of the JavaScript SDK's versionCompare; keep the two in step.
module SemverComparator
  NUMERIC_IDENTIFIER = /\A\d+\z/.freeze
  FIXED_DIGITS = 15
  FIXED_SCALE = 10**FIXED_DIGITS
  TRAILING_FIXED_ZEROS = /\.?0{0,15}\z/.freeze

  module_function

  def compare(evaluator, lhs, rhs)
    lhs_str = to_version_string(evaluator, lhs)
    rhs_str = to_version_string(evaluator, rhs)
    return nil if lhs_str.nil? || rhs_str.nil? || lhs_str.empty? || rhs_str.empty?

    l = parse(lhs_str)
    r = parse(rhs_str)
    return nil if l.nil? || r.nil?

    [l[:parts].size, r[:parts].size].max.times do |i|
      result = compare_identifiers(l[:parts][i] || "0", r[:parts][i] || "0")
      return result unless result.zero?
    end

    return 0 if l[:pre_release].empty? && r[:pre_release].empty?
    return 1 if l[:pre_release].empty?
    return -1 if r[:pre_release].empty?

    l_pre = l[:pre_release].split(".", -1)
    r_pre = r[:pre_release].split(".", -1)
    [l_pre.size, r_pre.size].max.times do |i|
      return -1 if i >= l_pre.size
      return 1 if i >= r_pre.size

      result = compare_identifiers(l_pre[i], r_pre[i])
      return result unless result.zero?
    end
    0
  end

  # Numbers are converted as JavaScript's stringConvert does,
  # x.toFixed(15) with trailing zeros trimmed, so 1.0000000000000002 is "1".
  # The general string_convert is left alone for the other operators.
  def to_version_string(evaluator, value)
    return evaluator.string_convert(value) unless value.is_a?(Numeric)

    to_fixed(value.to_f).sub(TRAILING_FIXED_ZEROS, "")
  end

  # Number.prototype.toFixed(15): the exact binary value rounded half up,
  # or the shortest round-trip text in exponent form from 1e21 up.
  def to_fixed(x)
    return x.to_s if x.nan? || x.infinite?
    return x.to_s.sub(/\.0(?=e)/, "") if x.abs >= 1e21

    scaled = (x.abs.to_r * FIXED_SCALE).round(half: :up)
    int, frac = scaled.divmod(FIXED_SCALE)
    "#{x.negative? ? '-' : ''}#{int}.#{frac.to_s.rjust(FIXED_DIGITS, '0')}"
  end

  def parse(version)
    v = version
    v = v[1..] if v.start_with?("v", "V")
    plus = v.index("+")
    v = v[0, plus] unless plus.nil?
    return nil if v.empty?

    core, *pre_release = v.split("-", -1)
    return nil if core.nil? || core.empty?

    { parts: core.split(".", -1), pre_release: pre_release.join("-") }
  end

  def compare_identifiers(a, b)
    a_num = a.match?(NUMERIC_IDENTIFIER)
    b_num = b.match?(NUMERIC_IDENTIFIER)

    if a_num && b_num
      a_norm = strip_leading_zeros(a)
      b_norm = strip_leading_zeros(b)
      return a_norm.size <=> b_norm.size unless a_norm.size == b_norm.size

      return a_norm <=> b_norm
    end
    return -1 if a_num
    return 1 if b_num

    a <=> b
  end

  def strip_leading_zeros(s)
    stripped = s.sub(/\A0+/, "")
    stripped.empty? ? "0" : stripped
  end
end
