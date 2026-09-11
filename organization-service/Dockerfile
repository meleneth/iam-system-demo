# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t organization_service .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name organization_service organization_service

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.6
# Build the pinned Thruster with ingress tracing; keep its proxy behavior.
FROM golang:1.24.4-bookworm AS traced-thruster
WORKDIR /src
ADD --checksum=sha256:222e15244983aa440154336b8797fad550affba2736868983320eb2f226630f3 https://codeload.github.com/basecamp/thruster/tar.gz/refs/tags/v0.1.14 /tmp/thruster.tar.gz
RUN tar -xzf /tmp/thruster.tar.gz --strip-components=1
COPY instrumentation/thruster/go.mod instrumentation/thruster/go.sum ./
RUN go mod download
COPY instrumentation/thruster/iam_tracing.go instrumentation/thruster/iam_tracing_test.go ./internal/
COPY instrumentation/thruster/tracing.patch /tmp/tracing.patch
RUN git apply /tmp/tracing.patch && go test ./internal && CGO_ENABLED=0 go build -mod=readonly -o /thrust ./cmd/thrust

FROM docker.io/library/ruby:$RUBY_VERSION-slim-trixie AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config libpq-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/




# Final stage for app image
FROM base

COPY --from=traced-thruster /thrust /usr/local/bin/iam-thrust
ENV IAM_RAILS_SERVICE_NAME="organization-service"

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

RUN apt-get update -qq && \
  apt-get install --no-install-recommends -y libpq5 && \
  rm -rf /var/lib/apt/lists /var/cache/apt/archives
# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
