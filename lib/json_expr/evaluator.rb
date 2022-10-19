# frozen_string_literal: true

class Evaluator
  def evaluate(expr)
    raise NotImplementedError.new("You must implement evaluate method.")
  end

  def boolean_convert(_)
    raise NotImplementedError.new("You must implement boolean convert method.")
  end

  def number_convert(_)
    raise NotImplementedError.new("You must implement number convert method.")
  end

  def string_convert(_)
    raise NotImplementedError.new("You must implement string convert method.")
  end

  def extract_var(_)
    raise NotImplementedError.new("You must implement extract var method.")
  end

  def compare(_, _)
    raise NotImplementedError.new("You must implement extract_var method.")
  end
end
