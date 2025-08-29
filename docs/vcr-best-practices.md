# VCR Best Practices for Coinbase Futures Bot

> **📝 NOTE** - This file has been moved from `doc/` to `docs/` folder as part of documentation consolidation.

This guide outlines best practices for using VCR (Video Cassette Recorder) in our test suite to ensure fast, reliable, and maintainable API integration tests.

## Overview

VCR records HTTP interactions during test runs and replays them for subsequent test runs, eliminating the need for real API calls and making tests faster and more reliable.

## Quick Start

### Using VCR Helper Methods

Instead of raw VCR syntax, use our helper methods:

```ruby
# For API tests with automatic response trimming
it "fetches candle data" do
  with_api_vcr("fetch_btc_candles", trim_responses: true) do
    candles = rest.fetch_candles(product_id: "BTC-USD", granularity: 3600)
    expect(candles).to be_an(Array)
  end
end

# For integration tests with full recording
it "processes complete workflow" do
  with_integration_vcr do
    result = SomeComplexService.call
    expect(result).to be_successful
  end
end

# For fast tests using existing cassettes only
it "validates response format" do
  with_fast_vcr do
    data = api_service.fetch_products
    expect(data).to have_key("products")
  end
end
```

### Automatic Cassette Naming

Use automatic naming for consistent organization:

```ruby
# Automatically generates: "MarketData_CoinbaseRest/fetch_candles_with_btc_usd"
it "fetch candles with BTC-USD" do
  with_api_vcr do
    # test implementation
  end
end
```

## Performance Optimizations

### 1. Response Trimming

Large candle datasets are automatically trimmed to improve test speed:

```ruby
# Automatically trims large candle arrays to first 3, middle 2, last 3
with_api_vcr("candles_trimmed", trim_responses: true) do
  candles = rest.fetch_candles(product_id: "BTC-USD", granularity: 300)
end
```

### 2. Smart Filtering

Dynamic data is automatically filtered to prevent cassette regeneration:

- **Timestamps**: ISO 8601 and Unix timestamps are replaced with placeholders
- **JWT Tokens**: Authentication tokens are filtered out
- **API Keys**: All Coinbase API credentials are masked
- **Headers**: Authentication headers are filtered

### 3. Fast vs Slow Tests

Separate tests by execution speed:

```ruby
# Fast tests - use existing cassettes only
RSpec.describe "Format validation", :vcr_fast do
  # Tests that verify response structure without API calls
end

# Slow tests - allow new recordings for comprehensive testing  
RSpec.describe "API integration", :vcr_slow do
  # Tests that may require fresh API data
end
```

## Test Organization

### Directory Structure

Cassettes are organized by test type:

```
spec/fixtures/vcr_cassettes/
├── services/
│   └── coinbase_rest/
├── jobs/
│   └── fetch_candles/
├── tasks/
│   └── market_data/
├── integration/
└── api/
```

### Naming Conventions

Use descriptive, hierarchical names:

```ruby
# Good
with_api_vcr("coinbase_rest/fetch_candles/btc_usd_1h")
with_integration_vcr("fetch_candles_job/full_workflow")

# Avoid
with_api_vcr("test1") 
with_api_vcr("candles")
```

## Environment Configuration

### Development

- **Record Mode**: `new_episodes` (records missing interactions)
- **Matching**: Method, URI, and body
- **Warnings**: Shows when new interactions are recorded

### CI/Production

- **Record Mode**: `none` (never records, fails if cassette missing)
- **Matching**: Strict matching including headers
- **Repeats**: Allows playback repeats for reliability

### Custom Recording

Override default behavior with environment variables:

```bash
# Force re-recording all cassettes
VCR_RECORD_MODE=all bundle exec rspec

# Record only new episodes
VCR_RECORD_MODE=new_episodes bundle exec rspec

# Use existing cassettes only
VCR_RECORD_MODE=none bundle exec rspec
```

## Maintenance

### Regular Tasks

Use built-in rake tasks for maintenance:

```bash
# Clean up old and unhealthy cassettes
rails vcr:cleanup

# Validate all cassettes for issues
rails vcr:validate

# Show cassette statistics
rails vcr:stats

# Organize cassettes into logical structure
rails vcr:organize

# Re-record all cassettes (requires API access)
rails vcr:update
```

### Health Monitoring

Cassettes are automatically checked for:

- **Corruption**: Invalid YAML structure
- **Age**: Cassettes older than 30 days
- **Size**: Unusually large response bodies
- **Placeholder Issues**: Too many filtered timestamps

### Expiration Policy

- **Development**: Cassettes expire after 30 days
- **CI**: Cassettes never expire automatically
- **Manual**: Use `rails vcr:cleanup` to remove expired cassettes

## Common Patterns

### Testing Error Responses

```ruby
it "handles API errors gracefully" do
  with_api_vcr("error_invalid_product") do
    expect {
      rest.fetch_candles(product_id: "INVALID")
    }.to raise_error(Faraday::ResourceNotFound)
  end
end
```

### Testing with Fresh Data

```ruby
it "processes latest market data" do
  with_fresh_vcr_cassette do
    # Forces new recording, removing existing cassette
    data = rest.fetch_latest_data
    expect(data).to be_recent
  end
end
```

### Testing Large Datasets

```ruby
it "handles large candle responses efficiently" do
  with_api_vcr("large_dataset", trim_responses: true) do
    # Automatically trims response for faster test execution
    candles = rest.fetch_candles(
      product_id: "BTC-USD",
      start_time: 30.days.ago,
      granularity: 300
    )
    expect(candles.length).to be <= 10 # Trimmed version
  end
end
```

## Troubleshooting

### Common Issues

1. **Cassette Not Found**
   - Ensure correct naming convention
   - Check if cassette was accidentally deleted
   - Run with `VCR_RECORD_MODE=new_episodes` to regenerate

2. **Test Failures After API Changes**
   - Delete affected cassettes and re-record
   - Use `rails vcr:update` for bulk re-recording

3. **Slow Test Suite**
   - Run `rails vcr:stats` to identify large cassettes
   - Use `:vcr_fast` tag for format validation tests
   - Enable response trimming for data-heavy endpoints

4. **Flaky Tests in CI**
   - Ensure all cassettes are committed
   - Check for timestamp filtering issues
   - Verify CI environment uses `record: :none`

### Debugging

Enable VCR debugging:

```ruby
# In test
VCR.turn_on!(debug: true)

# Or with environment variable
VCR_DEBUG=1 bundle exec rspec
```

## Security Considerations

- **Never commit real API keys** - All credentials are automatically filtered
- **Review cassettes before commit** - Ensure no sensitive data leaked through
- **Use `.gitattributes`** - Mark cassette files as generated content
- **Regular audits** - Use `rails vcr:validate` to check for security issues

## Performance Targets

With these optimizations, aim for:

- **Fast tests** (`:vcr_fast`): < 0.1 seconds per test
- **Slow tests** (`:vcr_slow`): < 2 seconds per test  
- **Total VCR test suite**: < 30 seconds
- **Individual cassettes**: < 50KB each

## Migration from Old VCR Usage

### Before (Manual)

```ruby
it "fetches data", :vcr do
  VCR.use_cassette("manual_cassette_name") do
    # test implementation
  end
end
```

### After (Helpers)

```ruby
it "fetches data" do
  with_api_vcr do
    # test implementation  
  end
end
```

The new helpers provide automatic naming, response trimming, and environment-appropriate configuration.