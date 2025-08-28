# Random Test Execution

This document describes the random test execution configuration implemented in the Coinbase futures bot to ensure test independence and catch hidden dependencies.

## Overview

Tests are now configured to run in random order to:
- Catch hidden dependencies between test cases
- Ensure tests are truly independent
- Improve test reliability and robustness
- Prevent order-dependent test failures

## Configuration

### RSpec Configuration

**Main Configuration (`.rspec`)**:
```
--require spec_helper
--format documentation
--format progress
--backtrace
--color
--tty
--order random
```

**Spec Helper (`spec/spec_helper.rb`)**:
```ruby
RSpec.configure do |config|
  # Configure random order execution with seed reporting
  config.order = :random
  
  # Print the seed for reproducible test runs
  Kernel.srand config.seed
end
```

**Parallel Tests (`.rspec_parallel`)**:
```
--color
--format progress
--profile 10
--order random
```

### CI/CD Configuration

The GitHub Actions CI pipeline has been updated to use random ordering:

```yaml
- name: Run tests with enhanced debugging
  run: |
    bundle exec rspec --format progress --order random --seed $RANDOM
```

## Usage

### Local Development

**Run tests with random order (default):**
```bash
bundle exec rspec
```

**Run with specific seed for debugging:**
```bash
bundle exec rspec --seed 12345
```

**Run without random order (if needed for debugging):**
```bash
bundle exec rspec --order defined
```

### Parallel Tests

Parallel test execution already includes random ordering:
```bash
bundle exec parallel_rspec spec/
```

## Seed Reporting

When tests run, the seed value is displayed at the end of the test output:
```
Randomized with seed 12345
```

### Reproducing Test Runs

If a test failure occurs in a specific order, you can reproduce it using the seed:

```bash
# Use the seed from the failed run
bundle exec rspec --seed 12345
```

## CI/CD Integration

The CI pipeline automatically uses random seeds on each run by using `$RANDOM` for the seed value. This ensures:
- Different execution orders on each CI run
- Ability to catch order-dependent issues early
- Improved confidence in test reliability

## Debugging Order Dependencies

If you suspect order dependencies:

1. **Run multiple times with different seeds:**
   ```bash
   for i in {1..5}; do
     echo "=== Run $i ==="
     bundle exec rspec --seed $RANDOM
   done
   ```

2. **Use bisect to find problematic tests:**
   ```bash
   bundle exec rspec --bisect
   ```

3. **Run specific test files in different orders:**
   ```bash
   bundle exec rspec spec/models/ --order random
   bundle exec rspec spec/services/ --order random
   ```

## Best Practices

### Writing Independent Tests

- Use `before(:each)` hooks for test setup
- Avoid shared state between tests
- Clean up after each test (databases, files, etc.)
- Use factories instead of fixtures when possible
- Mock external dependencies consistently

### Test Data Management

- Use transactional fixtures for database cleanup
- Clear caches and shared objects in setup/teardown
- Avoid global variables or class variables
- Use unique identifiers for test data

### Debugging Tips

1. **Consistent failures**: If tests fail consistently regardless of order, it's likely a real bug
2. **Intermittent failures**: If tests only fail in certain orders, there may be order dependencies
3. **Use specific seeds**: Always use the reported seed when investigating order-dependent failures

## Monitoring

### CI Success Rate

Monitor the CI pipeline for:
- Increased failure rates after implementing random order
- New intermittent failures that suggest order dependencies
- Performance impacts from random execution

### Local Development

Developers should:
- Run tests locally before pushing
- Use different seeds occasionally to catch issues early
- Report any order-dependent failures immediately

## Implementation Details

### Changes Made

1. **Added `--order random` to `.rspec`**
2. **Updated `spec/spec_helper.rb` with random order configuration**
3. **Modified CI pipeline to use random seeds**
4. **Maintained existing parallel test random ordering**

### Verification

The implementation has been verified by:
- Running test suite with multiple different seeds
- Confirming seed reporting in output
- Validating that execution order changes between runs
- Ensuring all configuration files are properly updated

## Troubleshooting

### Common Issues

**Test failures after enabling random order:**
- Check for shared state between tests
- Look for missing cleanup in teardown methods
- Verify database transactions are working correctly

**Performance concerns:**
- Random order should not significantly impact performance
- Monitor test suite execution time
- Consider splitting large test suites if needed

**Debugging specific failures:**
- Always use the exact seed from the failing run
- Isolate the problematic tests
- Use RSpec's bisect feature to find the minimal failing set

## Future Enhancements

Potential improvements:
- Automated detection of order-dependent tests
- Integration with test result tracking
- Custom seed selection strategies
- Enhanced reporting for CI/CD pipelines