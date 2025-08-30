feat(tests): Improve contract ID generation test coverage - reduce false positives

Resolves Linear issue FUT-32: Comprehensive overhaul of futures contract ID generation testing to eliminate false positives and improve real business logic validation.

## Key Improvements

### New Test Coverage
- **Real Date Logic Testing**: 18 new tests validating actual "last Friday of month" calculations without Date.current mocking
- **Edge Case Coverage**: Comprehensive testing of months with different Friday patterns, leap years, and year boundaries  
- **Integration Testing**: Full workflow tests creating actual TradingPair records with correct expiration dates
- **Regression Protection**: Tests that catch specific failures when core business logic breaks

### Reduced False Positives
- **Dynamic Contract ID Generation**: Replaced hardcoded values like "BIT-29AUG25-CDE" with calculated expected values
- **Real Algorithm Validation**: Tests now verify the actual "last Friday of month" calculation logic
- **Business Rule Enforcement**: Validates that generated dates are actually Fridays and in correct months

### Test Infrastructure Improvements
- **Reusable Test Helpers**: New ContractTestHelpers module with utilities for dynamic contract ID generation
- **Enhanced Factory**: TradingPair factory now generates dynamic contract IDs based on actual date logic
- **Better Test Organization**: Clear separation between mocked vs real date logic tests

## Files Added/Modified

### New Files
- `spec/services/market_data/contract_id_generation_spec.rb` - Comprehensive real logic tests (18 tests)
- `spec/support/contract_test_helpers.rb` - Reusable test utilities
- `TEST_COVERAGE_IMPROVEMENT_REPORT.md` - Detailed improvement documentation

### Enhanced Files  
- `spec/services/market_data/futures_contract_manager_spec.rb` - Added dynamic validation alongside existing tests
- `spec/factories/trading_pairs.rb` - Dynamic contract ID generation with configurable parameters

## Impact

- **Eliminated False Positives**: Tests now fail when `generate_current_month_contract_id` returns nil or invalid data
- **Improved Reliability**: Real date calculations ensure the algorithm works across different month patterns
- **Better Maintainability**: Dynamic generation reduces hardcoded dependencies and test brittleness
- **Enhanced Edge Case Coverage**: Tests validate behavior with months having 4 vs 5 Fridays, leap years, and boundary conditions

## Testing

- ✅ All new tests passing (18/18)
- ✅ Enhanced original tests with dual validation (dynamic + hardcoded verification)
- ✅ StandardRB formatting applied
- ✅ No regression in existing functionality

This resolves the core issue where tests were passing despite broken business logic by ensuring tests validate the actual contract ID generation algorithm rather than just format compliance.