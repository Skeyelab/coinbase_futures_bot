# frozen_string_literal: true

module Coinbase
  class Client
    def initialize(logger: Rails.logger)
      @logger = logger
      @advanced_trade = AdvancedTradeClient.new(logger: logger)
      @exchange = ExchangeClient.new(logger: logger)
    end

    # Advanced Trade API methods (futures, retail brokerage)
    def advanced_trade
      @advanced_trade
    end

    # Exchange API methods (spot trading)
    def exchange
      @exchange
    end

    # Convenience methods for futures positions
    def futures_positions(product_id: nil)
      @advanced_trade.list_futures_positions(product_id: product_id)
    end

    def futures_balance_summary
      @advanced_trade.get_futures_balance_summary
    end

    def margin_window
      @advanced_trade.get_current_margin_window
    end

    # Convenience methods for accounts
    def accounts
      @advanced_trade.get_accounts
    end

    def account(account_id)
      @advanced_trade.get_account(account_id)
    end

    # Convenience methods for market data
    def products
      @exchange.list_products
    end

    def product(product_id)
      @exchange.get_product(product_id)
    end

    def candles(product_id, start_time: nil, end_time: nil, granularity: 3600)
      @exchange.get_candles(product_id, start_time: start_time, end_time: end_time, granularity: granularity)
    end

    def ticker(product_id)
      @exchange.get_ticker(product_id)
    end

    def stats(product_id)
      @exchange.get_stats(product_id)
    end

    # Test authentication for both APIs
    def test_auth
      results = {}

      begin
        results[:advanced_trade] = @advanced_trade.test_auth
      rescue => e
        results[:advanced_trade] = { ok: false, error: e.class.to_s, message: e.message }
      end

      begin
        results[:exchange] = @exchange.test_auth
      rescue => e
        results[:exchange] = { ok: false, error: e.class.to_s, message: e.message }
      end

      results
    end

    # Get authentication status
    def auth_status
      {
        advanced_trade: @advanced_trade.instance_variable_get(:@authenticated),
        exchange: @exchange.instance_variable_get(:@authenticated)
      }
    end

    # Check if we can access futures data
    def can_access_futures?
      @advanced_trade.instance_variable_get(:@authenticated)
    end

    # Check if we can access spot trading
    def can_access_spot_trading?
      @exchange.instance_variable_get(:@authenticated)
    end
  end
end
