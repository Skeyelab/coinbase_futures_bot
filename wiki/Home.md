# Coinbase Futures Bot - Documentation Wiki

[![CI Status](https://github.com/Skeyelab/coinbase_futures_bot/workflows/CI/badge.svg)](https://github.com/Skeyelab/coinbase_futures_bot/actions)

Welcome to the comprehensive documentation for the **Coinbase Futures Bot** - an automated cryptocurrency futures trading system built with Rails 8.0.

## 🚀 Quick Navigation

### 📚 Getting Started
- **[Getting Started](Getting-Started)** - Complete setup guide with prerequisites
- **[Configuration](Configuration)** - Environment variables and settings
- **[Development](Development)** - Local development workflow and tools

### 🏗️ Architecture & Design
- **[Architecture Overview](Architecture)** - System design and component relationships
- **[Database Schema](Database-Schema)** - Models, relationships, and data structures
- **[API Reference](API-Reference)** - REST API endpoints with examples

### 🔧 Core Components
- **[Services Guide](Services-Guide)** - Business logic services (38 services)
- **[Background Jobs](Background-Jobs)** - Job system and scheduling (25+ jobs)
- **[Trading Strategies](Trading-Strategies)** - Strategy implementation and parameters
- **[WebSocket Integration](WebSocket-Integration)** - Real-time data streaming

### 📊 Trading & Operations
- **[Day Trading Guide](Day-Trading-Guide)** - Intraday trading strategies and risk management
- **[Risk Management](Risk-Management)** - Position sizing, stops, and safety controls
- **[Market Data Pipeline](Market-Data-Pipeline)** - Data ingestion and processing
- **[Sentiment Analysis](Sentiment-Analysis)** - News sentiment integration and scoring

### 🛠️ Development & Testing
- **[Testing Guide](Testing-Guide)** - Test suite organization and best practices
- **[Code Organization](Code-Organization)** - File structure and patterns
- **[Contributing](Contributing)** - Development workflow and standards

### 🚀 Operations & Deployment
- **[Deployment Guide](Deployment)** - Production deployment and operations
- **[Monitoring & Observability](Monitoring)** - Health checks, logging, and alerts
- **[Troubleshooting](Troubleshooting)** - Common issues and solutions

## 📈 Project Overview

The Coinbase Futures Bot is a sophisticated **day trading** system designed for short-term intraday positions with rapid entry/exit cycles. It features:

### Core Features
- **Multi-timeframe Trading**: 1h trend, 15m confirmation, 5m entry, 1m micro-timing
- **Real-time Market Data**: WebSocket integration with Coinbase APIs
- **Sentiment Analysis**: News sentiment integration with CryptoPanic
- **Risk Management**: Position sizing, stop losses, and futures contract management
- **Paper Trading**: Comprehensive simulation and backtesting
- **Background Processing**: Reliable job processing with GoodJob

### Technology Stack
- **Framework**: Rails 8.0 (API-only)
- **Language**: Ruby 3.2.4
- **Database**: PostgreSQL with time-series optimizations
- **Jobs**: GoodJob with cron scheduling
- **Testing**: RSpec with 94 test files and comprehensive coverage
- **APIs**: Coinbase Advanced Trade, Exchange API, CryptoPanic

## 📊 System Statistics

| Component | Count | Description |
|-----------|-------|-------------|
| **Services** | 38 | Business logic services across 6 modules |
| **Background Jobs** | 25+ | Scheduled and event-driven jobs |
| **API Endpoints** | 20+ | REST API with real-time WebSocket |
| **Database Tables** | 8 | Optimized for time-series data |
| **Test Files** | 94 | Comprehensive test coverage |
| **Documentation Pages** | 15+ | This wiki system |

## 🎯 Day Trading Focus

This system is specifically optimized for **intraday trading** with:

- **Position Duration**: Maximum 4-8 hours, typically 1-4 hours
- **Entry Precision**: 1-minute and 5-minute timeframe analysis
- **Risk Management**: Tighter stops (20-40 bps) for day trading
- **Exit Strategy**: Aggressive take-profit targets for quick wins
- **Market Hours**: Focus on high-liquidity periods

## 🔗 Quick Links

### Development Resources
- **GitHub Repository**: [Skeyelab/coinbase_futures_bot](https://github.com/Skeyelab/coinbase_futures_bot)
- **CI/CD Pipeline**: [GitHub Actions](https://github.com/Skeyelab/coinbase_futures_bot/actions)
- **Issue Tracking**: [Linear - FuturesBot Project](https://linear.app/ericdahl/project/futuresbot-c639185ec497/overview)

### API Documentation
- **Health Check**: `/up` - Basic health status
- **Extended Health**: `/health` - Database and system status
- **Real-time Signals**: `/signals` - Trading signal API
- **Position Management**: `/positions` - Position tracking UI
- **GoodJob Dashboard**: `/good_job` (development only)

### Key Configuration Files
- **Application Config**: `config/application.rb`
- **Database Schema**: `db/schema.rb`
- **Routes**: `config/routes.rb`
- **Job Schedules**: Defined in individual job classes

## 📝 Documentation Standards

This wiki follows these standards:

1. **Code Examples**: All major features include working code examples
2. **API Documentation**: Complete with curl examples and response formats
3. **Cross-References**: Extensive linking between related topics
4. **Maintenance**: Regular updates aligned with code changes
5. **Search Optimization**: Clear headings and consistent terminology

## 🆘 Getting Help

- **Setup Issues**: See [Getting Started](Getting-Started) and [Troubleshooting](Troubleshooting)
- **API Questions**: Check [API Reference](API-Reference) and [Services Guide](Services-Guide)
- **Trading Strategy**: Review [Trading Strategies](Trading-Strategies) and [Day Trading Guide](Day-Trading-Guide)
- **Development**: Follow [Development](Development) and [Contributing](Contributing) guides

---

**Last Updated**: January 2025 | **Version**: Rails 8.0 | **Ruby**: 3.2.4