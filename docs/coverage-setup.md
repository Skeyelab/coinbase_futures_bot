# SimpleCov CI Integration

This document describes the SimpleCov integration with our CI pipeline for comprehensive code coverage reporting.

## Overview

We use [SimpleCov](https://github.com/simplecov-ruby/simplecov) to track code coverage across our test suite. The coverage is integrated into our CI pipeline to ensure code quality and maintain coverage thresholds.

## Configuration

### SimpleCov Setup

SimpleCov is configured in `spec/spec_helper.rb` with the following features:

- **Rails Profile**: Uses the built-in Rails profile for optimal coverage tracking
- **Branch Coverage**: Enabled for comprehensive branch coverage analysis
- **Multiple Formatters**: HTML and JSON output formats
- **Coverage Groups**: Organized reporting by application components
- **CI-Specific Thresholds**: Different thresholds for local vs CI environments

### Coverage Thresholds

| Environment | Line Coverage | Branch Coverage |
|-------------|---------------|-----------------|
| Local Development | 90% | 80% |
| CI Pipeline | 85% | 75% |

### Excluded Files

The following files are excluded from coverage analysis:

- Test files (`/spec/`, `/test/`)
- Vendor files (`/vendor/`)
- Configuration files (`/config/`)
- Database files (`/db/`)
- Application base classes (ApplicationJob, ApplicationMailer, etc.)

## CI Integration

Our SimpleCov coverage is fully integrated into the main CI pipeline:

1. **Main CI Workflow** (`.github/workflows/ci.yml`)
   - Runs on pull requests and pushes to main
   - Includes linting, security scanning, and tests with coverage
   - Automatically generates coverage reports and artifacts
   - Checks coverage thresholds and provides guidance
   - Uploads coverage artifacts for review and badge generation

2. **Coverage Badge Workflow** (`.github/workflows/coverage-badge.yml`)
   - Automatically updates coverage badges in README
   - Runs after successful coverage generation
   - Provides visual coverage status indicators

### Coverage Artifacts

Coverage reports are uploaded as GitHub Actions artifacts:

- **HTML Report**: `coverage/index.html` - Human-readable coverage report
- **JSON Data**: `coverage/.resultset.json` - Raw coverage data for CI processing
- **Retention**: 30 days for main CI, 90 days for dedicated coverage runs

### PR Integration

When a pull request is created or updated:

1. Coverage workflow runs automatically
2. Coverage status is checked against thresholds
3. Coverage report is commented on the PR
4. Coverage badge is updated in README

## Local Development

### Running Coverage

```bash
# Run tests with coverage
bin/coverage

# Or use Rake directly
bundle exec rake coverage:run

# Check coverage thresholds
bundle exec rake coverage:check

# View coverage summary
bundle exec rake coverage:summary

# Clean coverage files
bundle exec rake coverage:clean
```

### Environment Variables

```bash
# Enable coverage
COVERAGE=true bundle exec rspec

# Run with CI thresholds (for testing CI behavior)
CI=true COVERAGE=true bundle exec rspec
```

### Coverage Report

After running coverage, open `coverage/index.html` in your browser to view:

- Overall coverage percentages
- File-by-file coverage breakdown
- Line-by-line coverage details
- Branch coverage information
- Coverage groups by application component

## Troubleshooting

### Common Issues

#### Coverage Not Generated

1. Ensure `COVERAGE=true` environment variable is set
2. Check that SimpleCov gems are installed
3. Verify `spec/spec_helper.rb` is properly configured

#### CI Failures

1. Check coverage thresholds are met
2. Verify SimpleCov configuration is CI-compatible
3. Check for SimpleCov processing errors in CI logs

#### Coverage Artifacts Missing

1. Ensure workflow has proper artifact upload configuration
2. Check that coverage files are generated before upload
3. Verify file paths in artifact configuration

### Debugging

#### Local Debugging

```bash
# Run with verbose output
COVERAGE=true bundle exec rspec --format documentation

# Check SimpleCov configuration
bundle exec rails console
> require 'simplecov'
> puts SimpleCov.configuration
```

#### CI Debugging

1. Check workflow logs for coverage generation
2. Verify environment variables are set correctly
3. Check for SimpleCov error messages

## Best Practices

### Writing Tests

1. **Aim for High Coverage**: Target 90%+ line coverage locally
2. **Test Edge Cases**: Ensure branch coverage for conditional logic
3. **Mock External Services**: Use VCR or mocks for external dependencies
4. **Test Error Paths**: Cover error handling and edge cases

### Maintaining Coverage

1. **Regular Checks**: Run coverage locally before committing
2. **Threshold Enforcement**: CI will fail if thresholds aren't met
3. **Coverage Reviews**: Review coverage reports during code reviews
4. **Incremental Improvement**: Gradually improve coverage over time

### CI Optimization

1. **Parallel Execution**: Coverage workflow runs independently
2. **Caching**: Coverage artifacts are cached for faster builds
3. **Artifact Management**: Proper retention policies for coverage data
4. **Status Checks**: Coverage status integrated into PR checks

## Configuration Files

### Key Files

- `spec/spec_helper.rb` - SimpleCov configuration
- `.github/workflows/ci.yml` - Main CI with coverage
- `.github/workflows/coverage.yml` - Dedicated coverage workflow
- `.github/workflows/coverage-badge.yml` - Badge updates
- `lib/tasks/coverage.rake` - Coverage Rake tasks
- `bin/coverage` - Coverage runner script

### Environment Variables

- `COVERAGE=true` - Enables SimpleCov
- `CI=true` - Sets CI-specific behavior
- `RAILS_ENV=test` - Ensures test environment

## Future Enhancements

### Planned Features

1. **Coverage Trends**: Track coverage over time
2. **Coverage Alerts**: Notify on coverage drops
3. **Coverage Dashboard**: Web-based coverage visualization
4. **Coverage Reports**: Automated coverage reporting

### Integration Ideas

1. **Slack Notifications**: Coverage status updates
2. **Coverage Metrics**: Integration with monitoring tools
3. **Coverage History**: Historical coverage tracking
4. **Coverage Goals**: Team coverage targets and tracking

## Support

For coverage-related issues:

1. Check this documentation
2. Review SimpleCov configuration
3. Check CI workflow logs
4. Consult the team for complex issues

## References

- [SimpleCov Documentation](https://github.com/simplecov-ruby/simplecov)
- [GitHub Actions Coverage](https://docs.github.com/en/actions/guides/storing-workflow-data-as-artifacts)
- [RSpec Coverage](https://rspec.info/documentation/)
- [Rails Testing](https://guides.rubyonrails.org/testing.html)

## **SimpleCov + Parallel RSpec Compatibility**

### **✅ Yes, It Works**
- SimpleCov automatically handles parallel test execution
- Coverage data is merged from all parallel processes
- Final coverage report combines results from all test workers

### **⚠️ Important Considerations**

1. **Process Isolation**
   - Each parallel process generates its own coverage data
   - SimpleCov merges these automatically when processes complete
   - Coverage files are written to shared directories

2. **File Locking**
   - SimpleCov uses file-based locking to prevent conflicts
   - Multiple processes can safely write coverage data simultaneously
   - Coverage data is atomically merged at the end

3. **Memory Usage**
   - Each parallel process loads SimpleCov
   - Slightly higher memory usage per process
   - Total memory usage scales with parallel processes

## **Best Practices for Parallel RSpec + SimpleCov**

### **In Our CI Workflow**
```yaml
<code_block_to_apply_changes_from>
```

### **Why We're Using Single Process in CI**
1. **Debugging** - Easier to troubleshoot failures
2. **Coverage Accuracy** - Single process ensures consistent coverage data
3. **CI Resources** - GitHub Actions runners have limited resources
4. **Stability** - Less complexity in CI environment

## **Local Development Options**

For local development, you can use either:

```bash
# Single process (current)
bundle exec rspec

# Parallel execution
bundle exec parallel_rspec

# Both with coverage
COVERAGE=true bundle exec parallel_rspec
```

## **Recommendation**

**Keep single process in CI** for now because:
- ✅ **Stability** - Less likely to have coverage merge issues
- ✅ **Debugging** - Easier to troubleshoot CI failures
- ✅ **Resource Efficiency** - Better for GitHub Actions runners

**Consider parallel for local development** when:
- 🔧 **Development** - Quick feedback during development
- 📊 **Coverage** - Same coverage accuracy with faster runs

Would you like me to add parallel RSpec options to our local development Rake tasks while keeping CI single-process for stability?
