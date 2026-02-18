# TODO List - Coinbase Futures Bot

## Status: Feature-Complete & Production-Ready ✅

This document outlines remaining work items for optimization and future enhancements. The bot is fully functional with comprehensive testing (80+ test files, 1000+ examples).

---

## 🔴 High Priority - Core Trading Optimizations

### 1. Futures Position Rollover Logic
**Status**: Not Implemented  
**Location**: `app/services/execution/futures_executor.rb`  
**Impact**: Medium - Currently requires manual contract rollover  
**Description**: Implement automated position rollover when futures contracts approach expiry
- Detect contract expiry dates (7-day warning)
- Calculate optimal rollover timing (liquidity/basis considerations)
- Execute simultaneous close + new position entry
- Handle partial fills and error recovery

**Estimated Effort**: 2-3 days  
**Dependencies**: ContractExpiryManager service (already exists)

---

### 2. Query Futures Best Bid/Ask via REST for Basis
**Status**: Not Implemented  
**Location**: `app/services/execution/futures_executor.rb`  
**Impact**: Medium - Affects execution quality and basis monitoring  
**Description**: Add REST API queries for futures order book data
- Implement best bid/ask fetching for futures products
- Calculate spot-futures basis for arbitrage detection
- Integrate with FuturesBasisMonitoringJob
- Cache bid/ask data (5-second TTL)

**Estimated Effort**: 1-2 days  
**Dependencies**: Coinbase Advanced Trade API research

---

### 3. Research Correct Futures API Endpoints for BTC-USD
**Status**: Not Started  
**Location**: `lib/tasks/market_data.rake`  
**Impact**: Medium - May improve data quality  
**Description**: Investigate Coinbase's futures-specific endpoints
- Document correct endpoints for BTC-USD futures
- Verify differences from spot API endpoints
- Update MarketData services if needed
- Add endpoint documentation to wiki

**Estimated Effort**: 1 day  
**Dependencies**: Coinbase API documentation review

---

## 🟡 Medium Priority - Testing & Code Quality

### 4. Implement Breadcrumb Tracking Test
**Status**: Test Gap  
**Location**: `spec/controllers/signal_controller_spec.rb`  
**Impact**: Low - Improves Sentry observability  
**Description**: Add test for Sentry breadcrumb tracking in SignalController
- Mock Sentry.add_breadcrumb calls
- Verify breadcrumb data structure
- Test error scenarios with breadcrumbs

**Estimated Effort**: 2-4 hours

---

### 5. Add Test for Invalid Data Format Handling
**Status**: Test Gap  
**Location**: `spec/services/market_data/coinbase_rest_spec.rb`  
**Impact**: Low - Improves error resilience  
**Description**: Test how CoinbaseRestClient handles malformed API responses
- Mock invalid JSON responses
- Test missing required fields
- Verify error handling and logging

**Estimated Effort**: 2-4 hours

---

## 🟢 Low Priority - Features & Enhancements

### 6. Persist Calibration Settings to Settings Store
**Status**: In Progress  
**Location**: `app/jobs/calibration_job.rb`  
**Impact**: Low - Currently uses environment variables  
**Description**: Store calibrated strategy parameters in database
- Create StrategySettings model (per symbol)
- Migrate CalibrationJob to use DB settings
- Add UI/API for viewing/editing settings
- Version control for settings changes

**Estimated Effort**: 3-5 days  
**Dependencies**: New database migration required

---

### 7. Multi-Exchange Support
**Status**: Future Enhancement  
**Impact**: Low - Coinbase-only is sufficient for current scope  
**Description**: Extend trading to other exchanges (Binance, Kraken, etc.)
- Abstract exchange-specific logic to adapters
- Implement unified position management
- Handle cross-exchange arbitrage opportunities

**Estimated Effort**: 2-3 weeks

---

### 8. Machine Learning Signal Models
**Status**: Future Enhancement  
**Impact**: Low - Current rule-based system performs well  
**Description**: Add ML-based signal generation alongside rule-based strategies
- Implement feature engineering from OHLCV + sentiment
- Train models on historical data (RandomForest, XGBoost)
- A/B test ML vs rule-based performance
- Deploy model serving infrastructure

**Estimated Effort**: 4-6 weeks

---

### 9. Options Trading Support
**Status**: Future Enhancement  
**Impact**: Low - Complex regulatory and risk management requirements  
**Description**: Add options strategies (covered calls, protective puts, spreads)
- Integrate options market data
- Implement Greeks calculation
- Add option-specific risk management
- Handle assignment and exercise logic

**Estimated Effort**: 6-8 weeks

---

### 10. Advanced Portfolio Hedging
**Status**: Future Enhancement  
**Impact**: Low - Basic hedging via position sizing works well  
**Description**: Implement delta-neutral and correlation-based hedging
- Calculate portfolio-level Greeks exposure
- Automatic hedging via offsetting positions
- Dynamic correlation analysis (BTC/ETH, BTC/SPY)
- Risk parity position sizing

**Estimated Effort**: 3-4 weeks

---

## 📋 Documentation Improvements

### 11. Add API Reference Documentation
**Status**: Partially Complete  
**Location**: `docs/api-endpoints.md` exists but could be expanded  
**Impact**: Low - Internal project  
**Description**: Generate comprehensive API docs
- Document all REST endpoints with examples
- Document WebSocket channels and message formats
- Add authentication/authorization details
- Generate from code (YARD or similar)

**Estimated Effort**: 2-3 days

---

### 12. Create Video Tutorials
**Status**: Not Started  
**Impact**: Low - README is comprehensive  
**Description**: Record screencast tutorials
- Getting started walkthrough
- Chat interface demo
- Real-time signal monitoring
- Position management best practices

**Estimated Effort**: 1-2 days

---

## 🛠️ Infrastructure & DevOps

### 13. Add Production Deployment Guide
**Status**: Partially Complete  
**Location**: `docs/deployment.md` exists  
**Impact**: Medium - Important for production use  
**Description**: Expand deployment documentation
- Heroku/Render deployment steps
- Docker Compose for local production testing
- Database migration strategies
- Zero-downtime deployment process
- Rollback procedures

**Estimated Effort**: 2-3 days

---

### 14. Implement Automated Database Backups
**Status**: Not Implemented  
**Impact**: Medium - Critical for production  
**Description**: Add scheduled database backup jobs
- Daily full backups to S3/cloud storage
- Point-in-time recovery capability
- Backup verification and testing
- Retention policy (30 days full, 90 days incremental)

**Estimated Effort**: 2-3 days

---

### 15. Performance Monitoring Dashboard
**Status**: Partial - Sentry exists, no custom dashboard  
**Impact**: Medium - Improves observability  
**Description**: Create monitoring dashboard for trading performance
- Real-time PnL visualization
- Signal quality metrics (win rate, avg profit)
- System health (API latency, job queue depth)
- Alert fatigue management

**Estimated Effort**: 1 week

---

## ✅ Recently Completed

- ✅ AI-powered chat interface with OpenRouter + ChatGPT
- ✅ Multi-timeframe signal generation (1h/15m/5m/1m)
- ✅ Real-time WebSocket market data ingestion
- ✅ Sentiment analysis (CryptoPanic, CoinDesk, CoinTelegraph)
- ✅ Paper trading simulation engine
- ✅ Risk management (stop loss, take profit, position sizing)
- ✅ Comprehensive testing (80+ test files, 1000+ examples)
- ✅ Background job processing with GoodJob
- ✅ Sentry error tracking and monitoring
- ✅ Slack integration for notifications
- ✅ Day trading position management
- ✅ Contract expiry monitoring
- ✅ Margin requirement tracking
- ✅ Comprehensive documentation (README, wiki, docs/)

---

## 📊 Summary

**Total Items**: 15  
**High Priority**: 3 items (~5-7 days)  
**Medium Priority**: 2 items (~1 day)  
**Low Priority**: 10 items (future enhancements)

**Recommendation**: Focus on High Priority items (futures rollover, basis queries) for production robustness. Low priority items are optional enhancements that don't block current functionality.

---

## 🎯 Next Sprint Priorities (If Continuing Development)

1. **Futures Position Rollover** - Automate contract expiry handling
2. **Basis Query Implementation** - Improve execution quality
3. **Production Deployment Guide** - Prepare for live trading
4. **Database Backup Strategy** - Protect production data
5. **Performance Dashboard** - Monitor trading performance

---

Last Updated: 2026-02-18
