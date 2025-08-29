# Code Coverage with SimpleCov

This project uses [SimpleCov](https://github.com/simplecov-ruby/simplecov) for comprehensive code coverage reporting.

## Quick Start

### Generate Coverage Reports

```bash
# Option 1: Use the coverage script (recommended)
bin/coverage

# Option 2: Use environment variable
COVERAGE=true bundle exec rspec

# Option 3: Run specific specs with coverage
COVERAGE=true bundle exec rspec spec/models/
```

### View Reports

After running tests with coverage:

- **HTML Report**: Open `coverage/index.html` in your browser
- **JSON Report**: Available at `coverage/coverage.json` for CI integration

## Configuration

SimpleCov is configured in `spec/spec_helper.rb` with:

### Coverage Thresholds
- **Line Coverage**: 90% minimum
- **Branch Coverage**: 80% minimum

### Coverage Groups
- **Models**: `app/models`
- **Controllers**: `app/controllers`
- **Services**: `app/services`
- **Jobs**: `app/jobs`
- **Lib**: `lib`
- **Config**: `config`

### Excluded Files
- Test files (`/spec/`, `/test/`)
- Vendor code (`/vendor/`)
- Configuration files (`/config/`)
- Database files (`/db/`)
- Rails boilerplate files

## Current Status

**Initial Baseline** (as of implementation):
- **Line Coverage**: 44.0% (2052/4664 lines)
- **Branch Coverage**: 48.01% (530/1104 branches)

## CI Integration

SimpleCov generates JSON reports for automated CI consumption:

```yaml
# Example GitHub Actions step
- name: Run tests with coverage
  run: COVERAGE=true bundle exec rspec
  
- name: Check coverage thresholds
  run: |
    if [ -f coverage/coverage.json ]; then
      echo "Coverage report generated successfully"
    fi
```

## Best Practices

1. **Always run coverage locally** before pushing changes
2. **Focus on testing critical business logic** to improve coverage
3. **Use coverage reports to identify untested code paths**
4. **Don't chase 100% coverage** - focus on meaningful tests
5. **Review coverage groups** to understand component-level coverage

## Troubleshooting

### Coverage not generating?
- Ensure `COVERAGE=true` environment variable is set
- Check that SimpleCov is loaded before application code
- Verify no syntax errors in `spec/spec_helper.rb`

### Low coverage numbers?
- Review which files are being tracked with `track_files` setting
- Check file filters to ensure important code isn't excluded
- Consider if private methods need testing (they count toward coverage)

## Files

- **Configuration**: `spec/spec_helper.rb`
- **Coverage Script**: `bin/coverage`
- **Reports Directory**: `coverage/` (gitignored)
- **Documentation**: `doc/coverage.md` (this file)