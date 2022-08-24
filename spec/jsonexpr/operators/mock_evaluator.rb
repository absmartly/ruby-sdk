class MockEvaluator
  def evaluate expr
    expr
  end
  
  def boolean_convert expr
    expr
  end
  
  def number_convert expr
    expr
  end
  
  def string_convert expr
    expr
  end
  
  def compare(lhr, rhs)
    #TODO: fill this method
  end
  
  def extract_var(path)
    case path
      when "a/b/c"
        return "abc"
      else
        return nil
    end
  end
end