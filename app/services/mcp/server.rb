# frozen_string_literal: true

module Mcp
  # Server is a minimal MCP (Model Context Protocol) server exposing bot state
  # and control as typed JSON-RPC 2.0 tools, so Claude Code (or any MCP client)
  # can query and control the bot with low latency and schema validation.
  #
  # #handle(request) is a pure function (request hash -> response hash, or nil
  # for notifications) so it is fully testable without stdio. #run wires it to a
  # newline-delimited JSON-RPC stdio loop for `bin/futuresbot mcp`.
  #
  # Reads reuse OperatorSnapshot (the one canonical state shape, #290). Control
  # reuses TradingHalt / Trading::CoinbasePositions. Money-touching tools
  # (close_position) require explicit confirmation, mirroring the /futuresbot
  # skill's policy at the protocol boundary, and are audit-logged.
  class Server
    PROTOCOL_VERSION = "2024-11-05"
    SERVER_NAME = "futuresbot"

    TOOLS = [
      {name: "get_status", description: "Live bot state: halt, dry-run, position counts, signals, eval freshness, paper account.",
       inputSchema: {type: "object", properties: {}}},
      {name: "get_positions", description: "Open positions with contract-size-aware unrealized PnL and a paper flag.",
       inputSchema: {type: "object", properties: {}}},
      {name: "get_signals", description: "Active trading signals (symbol, side, confidence, strategy, timestamp).",
       inputSchema: {type: "object", properties: {}}},
      {name: "get_sentiment", description: "Sentiment per enabled-contract symbol (z-score, event count, window), pipeline freshness, source health, and recent news headlines with scores.",
       inputSchema: {type: "object", properties: {}}},
      {name: "get_halt_status", description: "Trading halt / kill-switch state (active, halted, reason).",
       inputSchema: {type: "object", properties: {}}},
      {name: "halt_trading", description: "Halt trading (kill switch). Stops signal generation; places no orders.",
       inputSchema: {type: "object", properties: {reason: {type: "string"}}}},
      {name: "resume_trading", description: "Resume trading after a halt.",
       inputSchema: {type: "object", properties: {}}},
      {name: "close_position", description: "Close an open position. MONEY-TOUCHING: requires confirm=true.",
       inputSchema: {type: "object",
                     properties: {position_id: {type: "integer"}, confirm: {type: "boolean"}},
                     required: ["position_id"]}}
    ].freeze

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Handle a single JSON-RPC request. Returns a response hash, or nil for
    # notifications (which must not be answered).
    def handle(request)
      id = request["id"]
      case request["method"]
      when "initialize" then result(id, initialize_result)
      when "tools/list" then result(id, {tools: TOOLS})
      when "tools/call" then handle_tool_call(id, request["params"] || {})
      when %r{\Anotifications/} then nil
      else error(id, -32601, "Method not found: #{request["method"]}")
      end
    end

    # Newline-delimited JSON-RPC over stdio.
    def run(input: $stdin, output: $stdout)
      input.each_line do |line|
        line = line.strip
        next if line.empty?

        response = handle(JSON.parse(line))
        next if response.nil?

        output.puts(JSON.generate(response))
        output.flush
      end
    end

    private

    def initialize_result
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {tools: {}},
        serverInfo: {name: SERVER_NAME, version: "1.0.0"}
      }
    end

    def handle_tool_call(id, params)
      name = params["name"]
      args = params["arguments"] || {}

      case name
      when "get_status" then tool_result(id, OperatorSnapshot.new.status)
      when "get_positions" then tool_result(id, OperatorSnapshot.new.positions)
      when "get_signals" then tool_result(id, OperatorSnapshot.new.signals)
      when "get_sentiment" then tool_result(id, OperatorSnapshot.new.sentiment)
      when "get_halt_status" then tool_result(id, OperatorSnapshot.new.halt_status)
      when "halt_trading" then tool_result(id, TradingHalt.halt!(reason: args["reason"]))
      when "resume_trading" then tool_result(id, TradingHalt.resume!)
      when "close_position" then close_position(id, args)
      else error(id, -32602, "Unknown tool: #{name}")
      end
    end

    def close_position(id, args)
      unless args["confirm"] == true
        return tool_result(id, {
          error: "confirmation_required",
          message: "close_position is money-touching; call again with confirm: true after operator approval."
        }, is_error: true)
      end

      position = Position.find_by(id: args["position_id"])
      return tool_result(id, {error: "not_found", position_id: args["position_id"]}, is_error: true) unless position

      @logger.warn("[MCP] close_position confirmed: id=#{position.id} product=#{position.product_id}")
      result = Trading::CoinbasePositions.new.close_position(product_id: position.product_id, size: position.size)
      tool_result(id, {closed: true, position_id: position.id, product_id: position.product_id, result: result})
    rescue => e
      tool_result(id, {error: "close_failed", message: "#{e.class}: #{e.message}"}, is_error: true)
    end

    def tool_result(id, data, is_error: false)
      result(id, {content: [{type: "text", text: JSON.generate(data)}], isError: is_error})
    end

    def result(id, res)
      {jsonrpc: "2.0", id: id, result: res}
    end

    def error(id, code, message)
      {jsonrpc: "2.0", id: id, error: {code: code, message: message}}
    end
  end
end
