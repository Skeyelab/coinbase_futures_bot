require_relative "../lib/pyth_source"

RSpec.describe PythSource do
  # A real (abbreviated) Hermes v2 payload: fixed-point price + exponent.
  def payload
    {
      "parsed" => [
        {"id" => PythSource::FEEDS["GOLD"],
         "price" => {"price" => "425609300", "expo" => -5, "publish_time" => 1_785_953_641}},
        {"id" => PythSource::FEEDS["WTI"],
         "price" => {"price" => "7478466", "expo" => -5, "publish_time" => 1_785_953_700}}
      ]
    }
  end

  it "decodes fixed-point prices into floats keyed by symbol" do
    source = described_class.new(fetch: -> { payload })

    prices = source.latest

    expect(prices["GOLD"][:price]).to be_within(0.001).of(4256.093)
    expect(prices["WTI"][:price]).to be_within(0.001).of(74.78466)
    expect(prices["GOLD"][:publish_time]).to eq(1_785_953_641)
  end

  it "omits symbols the payload did not carry rather than inventing zeros" do
    source = described_class.new(fetch: -> { payload })

    expect(source.latest).not_to have_key("SILVER")
  end

  it "returns empty on a failed fetch instead of raising mid-collection" do
    source = described_class.new(fetch: -> { raise "network" })

    expect(source.latest).to eq({})
  end
end
