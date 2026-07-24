# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::Server do
  subject(:server) { described_class.new }

  def request(method, params = nil, id: 1)
    req = {"jsonrpc" => "2.0", "id" => id, "method" => method}
    req["params"] = params if params
    server.handle(req)
  end

  def tool_call(name, arguments = {})
    response = request("tools/call", {"name" => name, "arguments" => arguments})
    text = response.dig(:result, :content, 0, :text)
    {response: response, data: text && JSON.parse(text)}
  end

  describe "initialize" do
    it "returns the protocol version, server info, and tools capability" do
      res = request("initialize")[:result]

      expect(res[:protocolVersion]).to be_present
      expect(res[:serverInfo][:name]).to eq("futuresbot")
      expect(res[:capabilities]).to have_key(:tools)
    end
  end

  describe "notifications" do
    it "returns no response for a notification" do
      expect(server.handle({"jsonrpc" => "2.0", "method" => "notifications/initialized"})).to be_nil
    end
  end

  describe "tools/list" do
    it "lists read and control tools with input schemas" do
      tools = request("tools/list")[:result][:tools]
      names = tools.map { |t| t[:name] }

      expect(names).to include("get_status", "get_positions", "get_signals", "get_sentiment",
        "get_halt_status", "get_fee_truth", "halt_trading", "resume_trading", "close_position")
      expect(tools.find { |t| t[:name] == "halt_trading" }[:inputSchema]).to be_present
    end
  end

  describe "read tools" do
    it "get_status returns a parseable status document" do
      result = tool_call("get_status")

      expect(result[:data]).to include("as_of", "halt", "positions")
    end

    it "get_sentiment returns per-symbol scores and recent news" do
      create(:contract, enabled: true, product_id: "NOL-19AUG26-CDE", base_currency: "OIL")
      SentimentEvent.create!(source: "oilprice_rss", symbol: "OIL-USD", published_at: Time.current - 2.minutes,
        raw_text_hash: "oil-1", title: "Oil rises 4%", score: 1.0)

      result = tool_call("get_sentiment")

      expect(result[:data]).to include("symbols", "recent_events", "sources")
      expect(result[:data]["recent_events"].first).to include("title" => "Oil rises 4%")
    end

    it "get_fee_truth returns the modeled-vs-real fee comparison (issue #391)" do
      allow(Trading::FeeTruth).to receive(:call).and_return({status: "ok", perp_fills: 0})

      expect(tool_call("get_fee_truth")[:data]).to include("status" => "ok", "perp_fills" => 0)
    end

    it "get_fee_truth passes the limit argument through" do
      expect(Trading::FeeTruth).to receive(:call).with(hash_including(limit: 50)).and_return({status: "ok"})

      tool_call("get_fee_truth", {"limit" => 50})
    end
  end

  describe "control tools" do
    it "halt_trading halts and resume_trading restores, reflected in get_halt_status" do
      tool_call("halt_trading", {"reason" => "CPI print"})
      expect(tool_call("get_halt_status")[:data]).to include("halted" => true, "reason" => "CPI print")

      tool_call("resume_trading")
      expect(tool_call("get_halt_status")[:data]).to include("active" => true, "halted" => false)
    end
  end

  describe "close_position safety gate" do
    it "refuses without explicit confirmation" do
      position = create(:position, product_id: "NOL-19JUN26-CDE")

      result = tool_call("close_position", {"position_id" => position.id})

      expect(result[:response][:result][:isError]).to be true
      expect(result[:data]).to include("error" => "confirmation_required")
    end

    it "delegates to the executor when confirmed" do
      position = create(:position, product_id: "NOL-19JUN26-CDE")
      fake = instance_double(Trading::CoinbasePositions, close_position: {"success" => true})
      allow(Trading::CoinbasePositions).to receive(:new).and_return(fake)

      result = tool_call("close_position", {"position_id" => position.id, "confirm" => true})

      expect(fake).to have_received(:close_position).with(hash_including(product_id: "NOL-19JUN26-CDE"))
      expect(result[:data]).to include("closed" => true)
    end
  end

  describe "unknown method" do
    it "returns a JSON-RPC method-not-found error" do
      res = request("bogus/method")

      expect(res[:error][:code]).to eq(-32601)
    end
  end

  describe "#run (stdio loop)" do
    it "reads a JSON-RPC request line and writes a response line" do
      input = StringIO.new(%({"jsonrpc":"2.0","id":7,"method":"initialize"}\n))
      output = StringIO.new

      described_class.new.run(input: input, output: output)

      parsed = JSON.parse(output.string)
      expect(parsed["id"]).to eq(7)
      expect(parsed["result"]["serverInfo"]["name"]).to eq("futuresbot")
    end

    it "writes nothing for a notification" do
      input = StringIO.new(%({"jsonrpc":"2.0","method":"notifications/initialized"}\n))
      output = StringIO.new

      described_class.new.run(input: input, output: output)

      expect(output.string).to eq("")
    end
  end
end
