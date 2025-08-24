# Deployment and Operations Guide

## Overview

This guide covers deployment strategies, production configuration, monitoring, and operational procedures for the coinbase_futures_bot application.

## Deployment Architecture

### Production Environment Components

```
┌─────────────────────────────────────────────────────────────────┐
│                    Load Balancer / Reverse Proxy                │
│                         (Nginx/HAProxy)                         │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Application Servers                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │   Rails App 1   │  │   Rails App 2   │  │   Rails App N   │  │
│  │   (Puma)        │  │   (Puma)        │  │   (Puma)        │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Background Workers                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  GoodJob        │  │  GoodJob        │  │  GoodJob        │  │
│  │  Worker 1       │  │  Worker 2       │  │  Worker N       │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Data Layer                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │   PostgreSQL    │  │     Redis       │  │   File Storage  │  │
│  │   (Primary)     │  │   (Caching)     │  │   (Logs/Assets) │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                    External Services                            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  Coinbase APIs  │  │  CryptoPanic    │  │    Monitoring   │  │
│  │                 │  │     API         │  │   (Sentry)      │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Deployment Strategies

### 1. Docker Deployment

#### Dockerfile
```dockerfile
FROM ruby:3.2.2-alpine

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    postgresql-dev \
    nodejs \
    yarn \
    git

# Set up application directory
WORKDIR /app

# Install gems
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment true && \
    bundle config set --local without development test && \
    bundle install

# Copy application code
COPY . .

# Precompile assets (if any)
RUN bundle exec rails assets:precompile

# Expose port
EXPOSE 3000

# Start application
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

#### Docker Compose (Development)
```yaml
# docker-compose.yml
version: '3.8'

services:
  app:
    build: .
    ports:
      - "3000:3000"
    environment:
      - DATABASE_URL=postgresql://postgres:password@db:5432/coinbase_futures_bot_production
      - RAILS_ENV=production
    depends_on:
      - db
      - redis
    volumes:
      - ./log:/app/log

  worker:
    build: .
    command: bundle exec good_job start
    environment:
      - DATABASE_URL=postgresql://postgres:password@db:5432/coinbase_futures_bot_production
      - RAILS_ENV=production
    depends_on:
      - db
      - redis

  db:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=password
      - POSTGRES_DB=coinbase_futures_bot_production
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:6-alpine
    volumes:
      - redis_data:/data

volumes:
  postgres_data:
  redis_data:
```

### 2. Heroku Deployment

#### Procfile
```
web: bundle exec puma -C config/puma.rb
worker: bundle exec good_job start
release: bundle exec rails db:migrate
```

#### Heroku Configuration
```bash
# Create Heroku app
heroku create coinbase-futures-bot

# Add PostgreSQL addon
heroku addons:create heroku-postgresql:standard-0

# Set environment variables
heroku config:set RAILS_ENV=production
heroku config:set RAILS_MASTER_KEY=$(cat config/master.key)
heroku config:set COINBASE_API_KEY=your_api_key
heroku config:set COINBASE_API_SECRET=your_api_secret
heroku config:set CRYPTOPANIC_TOKEN=your_token

# Deploy
git push heroku main

# Scale workers
heroku ps:scale worker=2
```

### 3. Kubernetes Deployment

#### Deployment Manifest
```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coinbase-futures-bot
spec:
  replicas: 3
  selector:
    matchLabels:
      app: coinbase-futures-bot
  template:
    metadata:
      labels:
        app: coinbase-futures-bot
    spec:
      containers:
      - name: app
        image: coinbase-futures-bot:latest
        ports:
        - containerPort: 3000
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: database-url
        - name: COINBASE_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: coinbase-api-key
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coinbase-futures-worker
spec:
  replicas: 2
  selector:
    matchLabels:
      app: coinbase-futures-worker
  template:
    metadata:
      labels:
        app: coinbase-futures-worker
    spec:
      containers:
      - name: worker
        image: coinbase-futures-bot:latest
        command: ["bundle", "exec", "good_job", "start"]
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: database-url
```

## Production Configuration

### Environment Variables

#### Core Application Settings
```bash
# Application
RAILS_ENV=production
SECRET_KEY_BASE=your_very_long_secret_key_base
RAILS_LOG_LEVEL=info
FORCE_SSL=true

# Database
DATABASE_URL=postgresql://user:password@host:port/database
RAILS_MAX_THREADS=5

# External APIs
COINBASE_API_KEY=production_api_key
COINBASE_API_SECRET=production_private_key
CRYPTOPANIC_TOKEN=production_token

# Feature Flags
SENTIMENT_ENABLE=true
SENTIMENT_Z_THRESHOLD=1.5
PAPER_TRADING_MODE=false
```

#### Job Processing Configuration
```bash
# GoodJob Workers
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=10
GOOD_JOB_POLL_INTERVAL=5
GOOD_JOB_CLEANUP_INTERVAL=1  # days

# Job Schedules (production tuned)
CANDLES_CRON="0 */1 * * *"      # Every hour
PAPER_CRON="*/30 * * * *"       # Every 30 minutes
SENTIMENT_FETCH_CRON="*/5 * * * *"  # Every 5 minutes
```

#### Monitoring and Logging
```bash
# Error tracking
SENTRY_DSN=https://your-sentry-dsn@sentry.io/project-id
SENTRY_ENVIRONMENT=production

# Logging
LOG_LEVEL=info
RAILS_LOG_TO_STDOUT=true

# Performance monitoring
NEW_RELIC_LICENSE_KEY=your_new_relic_key
NEW_RELIC_APP_NAME=coinbase-futures-bot
```

### Database Configuration

#### Production Database Setup
```bash
# Create production database
createdb coinbase_futures_bot_production

# Create dedicated user
createuser --pwprompt coinbase_futures_bot

# Grant permissions
psql -c "GRANT ALL PRIVILEGES ON DATABASE coinbase_futures_bot_production TO coinbase_futures_bot;"
```

#### Connection Pool Settings
```ruby
# config/database.yml
production:
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 20 } %>
  url: <%= ENV["DATABASE_URL"] %>

  # Production optimizations
  prepared_statements: true
  connect_timeout: 5
  checkout_timeout: 5
  reaping_frequency: 10
```

#### Database Maintenance
```bash
# Regular maintenance tasks
bundle exec rails db:migrate
bundle exec rails db:seed  # If needed

# Backup database
pg_dump $DATABASE_URL > backup_$(date +%Y%m%d_%H%M%S).sql

# Restore database
psql $DATABASE_URL < backup_file.sql
```

## Security Configuration

### SSL/TLS Setup

#### Nginx Configuration
```nginx
# /etc/nginx/sites-available/coinbase-futures-bot
server {
    listen 80;
    server_name your-domain.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    ssl_certificate /path/to/ssl/certificate.crt;
    ssl_certificate_key /path/to/ssl/private.key;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

#### Rails Security Configuration
```ruby
# config/environments/production.rb
Rails.application.configure do
  # Force SSL
  config.force_ssl = true

  # Secure headers
  config.ssl_options = {
    redirect: { status: 301, port: 443 },
    secure_cookies: true,
    hsts: {
      expires: 1.year,
      subdomains: true,
      preload: true
    }
  }
end
```

### API Security

#### Rate Limiting
```ruby
# Gemfile
gem 'rack-attack'

# config/initializers/rack_attack.rb
Rack::Attack.throttle('api/ip', limit: 100, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/api/')
end

Rack::Attack.throttle('sentiment/ip', limit: 300, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/sentiment/')
end
```

#### Authentication (if needed)
```ruby
# API key authentication
class ApplicationController < ActionController::API
  before_action :authenticate_request, if: :protected_endpoint?

  private

  def authenticate_request
    api_key = request.headers['X-API-Key']
    unless valid_api_key?(api_key)
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end

  def protected_endpoint?
    # Define which endpoints require authentication
    false
  end
end
```

## Monitoring and Alerting

### Application Monitoring

#### Health Checks
```ruby
# config/routes.rb
get '/health', to: 'health#show'
get '/health/detailed', to: 'health#detailed'

# app/controllers/health_controller.rb
class HealthController < ApplicationController
  def show
    render json: { status: 'ok', timestamp: Time.current }
  end

  def detailed
    checks = {
      database: database_check,
      jobs: job_queue_check,
      external_apis: api_check,
      memory: memory_check
    }

    status = checks.values.all? ? :ok : :service_unavailable
    render json: { status: status, checks: checks }, status: status
  end

  private

  def database_check
    ActiveRecord::Base.connection.execute('SELECT 1')
    { status: 'ok' }
  rescue => e
    { status: 'error', error: e.message }
  end

  def job_queue_check
    failed_jobs = GoodJob::Job.where.not(error: nil).where('created_at > ?', 1.hour.ago).count
    {
      status: failed_jobs > 10 ? 'warning' : 'ok',
      failed_jobs_last_hour: failed_jobs,
      queue_depth: GoodJob::Job.where(finished_at: nil).count
    }
  end
end
```

#### Metrics Collection
```ruby
# Add StatsD metrics (if using DataDog/StatsD)
class ApplicationController < ActionController::API
  around_action :track_performance

  private

  def track_performance
    start_time = Time.current
    yield
  ensure
    duration = Time.current - start_time
    StatsD.histogram('api.request.duration', duration)
    StatsD.increment("api.request.#{response.status}")
  end
end
```

### Infrastructure Monitoring

#### Server Monitoring
```bash
# Install monitoring agents
# New Relic
curl -Ls https://download.newrelic.com/install/newrelic-cli/scripts/install.sh | bash
newrelic install

# DataDog
DD_API_KEY=your_key DD_SITE="datadoghq.com" bash -c "$(curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh)"
```

#### Log Aggregation
```yaml
# docker-compose.yml (add logging driver)
services:
  app:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # Or use centralized logging
  app:
    logging:
      driver: fluentd
      options:
        fluentd-address: localhost:24224
        tag: coinbase-futures-bot
```

### Alerting Setup

#### Critical Alerts
```yaml
# Example alert configuration (adjust for your monitoring system)
alerts:
  - name: "Application Down"
    condition: "http_response_code != 200"
    threshold: "3 failures in 5 minutes"
    notification: "immediate"

  - name: "High Error Rate"
    condition: "error_rate > 5%"
    threshold: "sustained for 10 minutes"
    notification: "immediate"

  - name: "Job Queue Backed Up"
    condition: "job_queue_depth > 1000"
    threshold: "sustained for 15 minutes"
    notification: "urgent"

  - name: "Database Connection Issues"
    condition: "db_connection_errors > 0"
    threshold: "any occurrence"
    notification: "immediate"
```

## Deployment Procedures

### Pre-deployment Checklist

#### Code Quality
```bash
# Run all tests
bundle exec rspec

# Security scan
bundle exec brakeman

# Style check
bundle exec rubocop

# Dependency audit
bundle audit
```

#### Configuration Validation
```bash
# Verify environment variables
bundle exec rails runner "puts ENV.keys.grep(/COINBASE|DATABASE|RAILS/).sort"

# Test database connectivity
bundle exec rails runner "ActiveRecord::Base.connection.execute('SELECT 1')"

# Validate configuration
bundle exec rails runner "Rails.application.config_for(:application)"
```

### Deployment Steps

#### Standard Deployment
```bash
# 1. Update codebase
git pull origin main

# 2. Install dependencies
bundle install --deployment --without development test

# 3. Run database migrations
RAILS_ENV=production bundle exec rails db:migrate

# 4. Restart application
sudo systemctl restart coinbase-futures-bot

# 5. Restart workers
sudo systemctl restart coinbase-futures-worker

# 6. Verify deployment
curl -f https://your-domain.com/health
```

#### Zero-downtime Deployment
```bash
# 1. Deploy to staging instances
deploy_to_staging()

# 2. Run health checks on staging
verify_staging_health()

# 3. Update production instances one by one
for instance in $production_instances; do
  deploy_to_instance($instance)
  wait_for_health_check($instance)
  sleep 30  # Allow instance to stabilize
done

# 4. Verify all instances healthy
verify_production_health()
```

### Rollback Procedures

#### Quick Rollback
```bash
# 1. Identify last good commit
git log --oneline -10

# 2. Revert to previous version
git checkout previous_good_commit

# 3. Restart services
sudo systemctl restart coinbase-futures-bot
sudo systemctl restart coinbase-futures-worker

# 4. Verify rollback
curl -f https://your-domain.com/health
```

#### Database Rollback (if needed)
```bash
# 1. Stop application
sudo systemctl stop coinbase-futures-bot

# 2. Rollback migrations
RAILS_ENV=production bundle exec rails db:rollback STEP=1

# 3. Restore from backup (if necessary)
psql $DATABASE_URL < backup_before_deployment.sql

# 4. Restart application
sudo systemctl start coinbase-futures-bot
```

## Performance Optimization

### Application Tuning

#### Puma Configuration
```ruby
# config/puma.rb
workers ENV.fetch("WEB_CONCURRENCY") { 4 }
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count

preload_app!

on_worker_boot do
  ActiveRecord::Base.establish_connection
end

# Memory management
worker_timeout 60
worker_shutdown_timeout 8
```

#### Database Optimization
```ruby
# config/application.rb
config.active_record.database_selector = { delay: 2.seconds }
config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
config.active_record.database_resolver_context = ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
```

### Caching Strategy

#### Redis Caching
```ruby
# config/environments/production.rb
config.cache_store = :redis_cache_store, {
  url: ENV['REDIS_URL'],
  expires_in: 1.hour,
  namespace: 'coinbase_futures_bot'
}

# Use caching in services
def expensive_calculation
  Rails.cache.fetch("calculation_#{key}", expires_in: 30.minutes) do
    perform_calculation
  end
end
```

### Job Processing Optimization

#### GoodJob Tuning
```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.execution_mode = :external
  config.good_job.max_threads = 10
  config.good_job.poll_interval = 5.seconds
  config.good_job.max_cache = 10000

  # Queue-specific workers
  config.good_job.queues = 'default:5;market_data:3;sentiment:2'
end
```

## Backup and Recovery

### Database Backups

#### Automated Backup Script
```bash
#!/bin/bash
# backup_database.sh

BACKUP_DIR="/var/backups/coinbase_futures_bot"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.sql"

# Create backup directory
mkdir -p $BACKUP_DIR

# Create backup
pg_dump $DATABASE_URL > $BACKUP_FILE

# Compress backup
gzip $BACKUP_FILE

# Remove old backups (keep 30 days)
find $BACKUP_DIR -name "*.sql.gz" -mtime +30 -delete

# Upload to cloud storage (optional)
aws s3 cp $BACKUP_FILE.gz s3://your-backup-bucket/database/
```

#### Backup Schedule
```bash
# crontab -e
# Daily backup at 2 AM
0 2 * * * /path/to/backup_database.sh

# Weekly full backup at 1 AM Sunday
0 1 * * 0 /path/to/full_backup.sh
```

### Disaster Recovery

#### Recovery Procedures
```bash
# 1. Stop application
sudo systemctl stop coinbase-futures-bot

# 2. Restore database
gunzip -c backup_file.sql.gz | psql $DATABASE_URL

# 3. Verify data integrity
bundle exec rails runner "puts Candle.count; puts TradingPair.count"

# 4. Start application
sudo systemctl start coinbase-futures-bot

# 5. Verify functionality
curl -f https://your-domain.com/health
```

## Maintenance Procedures

### Regular Maintenance Tasks

#### Weekly Tasks
```bash
# Update system packages
sudo apt update && sudo apt upgrade

# Rotate logs
sudo logrotate -f /etc/logrotate.conf

# Database maintenance
bundle exec rails runner "ActiveRecord::Base.connection.execute('VACUUM ANALYZE')"

# Clean old job records
bundle exec rails runner "GoodJob.cleanup_preserved_jobs(older_than: 7.days)"
```

#### Monthly Tasks
```bash
# Security updates
bundle update --conservative

# Performance review
bundle exec rails runner "
puts 'Slowest queries:'
ActiveRecord::Base.connection.execute('
  SELECT query, mean_time, calls
  FROM pg_stat_statements
  ORDER BY mean_time DESC
  LIMIT 10
')
"

# Backup verification
test_backup_restore()
```

### Scaling Procedures

#### Horizontal Scaling
```bash
# Add new application server
provision_new_server()
configure_load_balancer()

# Add new worker
deploy_worker_instance()
update_worker_pool()

# Scale down
remove_instance_from_load_balancer()
drain_connections()
shutdown_instance()
```

#### Database Scaling
```bash
# Read replicas
setup_read_replica()
configure_database_routing()

# Connection pooling
install_pgbouncer()
configure_connection_pooling()
```

## Troubleshooting

### Common Production Issues

#### Application Won't Start
```bash
# Check logs
tail -f log/production.log

# Check environment
bundle exec rails runner "puts Rails.env"

# Verify database
bundle exec rails dbconsole

# Check dependencies
bundle check
```

#### Job Processing Issues
```bash
# Check job queue
bundle exec rails runner "puts GoodJob::Job.count"

# Check failed jobs
bundle exec rails runner "puts GoodJob::Job.where.not(error: nil).count"

# Restart workers
sudo systemctl restart coinbase-futures-worker
```

#### Performance Issues
```bash
# Check memory usage
free -h

# Check database connections
bundle exec rails runner "puts ActiveRecord::Base.connection_pool.stat"

# Check slow queries
tail -f log/production.log | grep "SLOW QUERY"
```

### Emergency Procedures

#### Circuit Breaker
```ruby
# Disable external API calls
ENV['EMERGENCY_MODE'] = 'true'
sudo systemctl restart coinbase-futures-bot

# Stop job processing
sudo systemctl stop coinbase-futures-worker
```

#### Data Corruption
```bash
# 1. Stop all services immediately
sudo systemctl stop coinbase-futures-bot coinbase-futures-worker

# 2. Assess damage
bundle exec rails runner "check_data_integrity()"

# 3. Restore from backup
restore_from_backup()

# 4. Verify integrity
verify_data_integrity()

# 5. Restart services
sudo systemctl start coinbase-futures-bot coinbase-futures-worker
```
