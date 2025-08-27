#!/bin/bash

# Coinbase Futures Bot - 10-Contract Trading Setup Script
# This script helps you configure and start trading with 10+ contract exposure

echo "🚀 Coinbase Futures Bot - 10-Contract Trading Setup"
echo "=================================================="

# Set environment variables for 10-contract trading ($1000+ exposure)
export SIGNAL_EQUITY_USD=5000
export REALTIME_SIGNAL_MIN_CONFIDENCE=65
export REALTIME_SIGNAL_MAX_PER_HOUR=8
export REALTIME_SIGNAL_EVALUATION_INTERVAL=45
export STRATEGY_RISK_FRACTION=0.02
export STRATEGY_TP_TARGET=0.006
export STRATEGY_SL_TARGET=0.004

echo "✅ Environment variables set:"
echo "   SIGNAL_EQUITY_USD: $SIGNAL_EQUITY_USD"
echo "   Min Confidence: $REALTIME_SIGNAL_MIN_CONFIDENCE%"
echo "   Max Signals/Hour: $REALTIME_SIGNAL_MAX_PER_HOUR"
echo "   Risk per Trade: $((SIGNAL_EQUITY_USD * STRATEGY_RISK_FRACTION))$"
echo ""

echo "📊 Position Size Calculation:"
echo "   Max loss per trade: $((SIGNAL_EQUITY_USD * STRATEGY_RISK_FRACTION))"
echo "   BTC/ETH futures contract: $100"
echo "   Your comfort zone: 10 contracts ($1000 exposure)"
echo "   Daily risk budget: $((SIGNAL_EQUITY_USD * STRATEGY_RISK_FRACTION * 8)) (max 8 trades)"
echo "   Expected position size: 5-15 contracts ($500-$1500 exposure)"
echo ""

echo "🔄 Setting up market data..."
cd /Users/edahl/Documents/GitHub/coinbase_futures_bot

# Sync products
echo "   Syncing trading products..."
bin/rake market_data:upsert_futures_products

# Backfill candle data
echo "   Backfilling candle data..."
bin/rake market_data:backfill_1h_candles[2]  # 2 days of hourly data
bin/rake market_data:backfill_15m_candles[2] # 2 days of 15m data
bin/rake market_data:backfill_5m_candles[1]  # 1 day of 5m data

echo ""
echo "📈 Available Trading Pairs:"
bin/rails runner "TradingPair.enabled.each { |p| puts \"   #{p.product_id} - #{p.contract_type || 'spot'}\" }"

echo ""
echo "🎯 Starting Real-Time Trading System..."
echo ""
echo "⚠️  IMPORTANT SAFETY REMINDERS:"
echo "   • Never risk more than you can afford to lose"
echo "   • This is experimental software - use at your own risk"
echo "   • Monitor positions closely, especially with larger sizes"
echo "   • Stop trading if you lose 5% of your capital ($250)"
echo "   • Your positions can move $1000+ - have stop losses ready"
echo ""
echo "📊 To monitor signals in another terminal:"
echo "   curl 'http://localhost:3000/signals/active' | jq ."
echo ""
echo "🛑 To stop trading:"
echo "   FORCE=true bin/rake realtime:cancel_all"
echo ""

# Start the real-time system
SIGNAL_EQUITY_USD=5000 bin/rake realtime:signals
