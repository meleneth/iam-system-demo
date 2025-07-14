FROM ruby:3.4.4-bookworm
RUN apt-get update -qq && apt-get install -y nodejs postgresql-client
# Common dependencies
RUN apt-get update -qq \
  && DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    build-essential \
    gnupg2 \
    curl \
    less \
    git \
    nodejs \
    postgresql-client \
  && apt-get clean \
  && rm -rf /var/cache/apt/archives/* \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
  && truncate -s 0 /var/log/*log

ENV BUNDLE_PATH=/tmp/bundle BUNDLE_USER_HOME=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle/config
ENV PATH="/tmp/bundle/bin:$PATH"

ARG USER_ID
ARG GROUP_ID
RUN addgroup --gid $GROUP_ID rubyuser
RUN adduser --disabled-password --gecos '' --uid $USER_ID --gid $GROUP_ID rubyuser
RUN mkdir -p /tmp/bundle && chown -R rubyuser:rubyuser /tmp/bundle
RUN mkdir -p /app && chown -R rubyuser:rubyuser /app
WORKDIR /app
USER rubyuser
RUN bundle config set --global path /tmp/bundle
RUN bundle config set --global bin /tmp/bundle/bin
RUN gem update bundle
RUN gem update --system
RUN gem install rails pg mysql2 minitest rspec-rails puma jbuilder sqlite3 redis kredis bcrypt image_processing graphql
