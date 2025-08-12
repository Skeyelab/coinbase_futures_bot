# Dev container for Cursor background agent
# - Designed for Rails 8 API app using Ruby 3.2.x and PostgreSQL
# - Installs developer tooling (git, node/npm, editors, postgres client, build deps)
# - Does NOT copy application code; clone your repo after container starts

FROM ruby:3.2.2-slim

ARG DEBIAN_FRONTEND=noninteractive

# Base OS packages and developer tooling
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       git \
       curl \
       ca-certificates \
       tzdata \
       pkg-config \
       libpq-dev \
       libssl-dev \
       libreadline-dev \
       zlib1g-dev \
       libyaml-dev \
       postgresql-client \
       nodejs \
       npm \
       vim \
       nano \
       less \
       jq \
       procps \
       openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Ruby and Bundler setup
ENV LANG=C.UTF-8 \
    TZ=UTC \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    RAILS_ENV=development \
    RACK_ENV=development

# Match Gemfile.lock bundler version
RUN gem update --system \
    && gem install bundler:2.7.1 \
    && bundle config set path "$BUNDLE_PATH"

# Enable corepack so yarn/pnpm shims are available when needed
RUN corepack enable || true

# Ensure Yarn is available even if the distro Node lacks corepack
RUN npm install -g yarn

# Non-root user and working directory
RUN useradd -ms /bin/bash dev \
    && chown -R dev:dev /home/dev /usr/local/bundle

USER dev
WORKDIR /home/dev

SHELL ["bash", "-lc"]

# Default to an interactive shell; clone your repo and then bundle install
CMD ["bash"]


