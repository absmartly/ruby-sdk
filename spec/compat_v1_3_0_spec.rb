# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "1.3.0 consumer compatibility" do
  it "runs a customer app written against the 1.3.0 README with only require \"absmartly\"" do
    lib = File.expand_path("../lib", __dir__)
    script = File.expand_path("compat/v1_3_0_consumer.rb", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-W0", "-I", lib, script)
    expect(out.lines.grep_v(/\Aok /)).to be_empty, out + err
    expect(status.success?).to be(true), out + err
  end
end
