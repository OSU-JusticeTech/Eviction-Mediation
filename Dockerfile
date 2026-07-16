# syntax=docker/dockerfile:1
# check=error=true

# Production-focused Dockerfile (use in CI/CD and deployment)
# Build:   docker build -t app .
# Run:     docker run -d -p 3000:3000 -e RAILS_MASTER_KEY=<value> --name app app

ARG RUBY_VERSION=3.3.4
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages (added nodejs + freetds runtime for SQL Server)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    curl libjemalloc2 libvips sqlite3 nodejs freetds-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

# ----------------------------
# Build stage
# ----------------------------
FROM base AS build

# Install build deps for native gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    build-essential git pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy app code
COPY . .

# Precompile bootsnap + assets
RUN bundle exec bootsnap precompile app/ lib/
RUN chmod +x ./bin/*
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# ----------------------------
# Final runtime image
# ----------------------------
FROM base

# Copy built gems + code
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Add non-root user
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint & default command
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Expose app port
EXPOSE 3000

# Run Rails server by default
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
