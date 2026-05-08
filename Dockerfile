FROM ruby:3.3-slim-bookworm

ENV LANG=C.UTF-8 \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_FROZEN="1"

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
      pkg-config \
      curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install gems first so the bundle layer is cached when only app code changes.
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy the rest of the app.
COPY . .

# Defensive: ensure entrypoint is executable on hosts that drop the bit (Windows checkouts).
RUN chmod +x bin/start bin/setup

ENV APP_ENV=production \
    PORT=9292 \
    DATABASE_PATH=/data/production.sqlite3

EXPOSE 9292

CMD ["bin/start"]
