# Puma config — single-process by design.
#
# Forking workers with SQLite produces "prepare called on a closed database"
# errors because the parent's open connection isn't valid in the child after
# fork. Render auto-sets WEB_CONCURRENCY=1 which would fork once; we override
# that here. For higher-throughput hosts, swap SQLite for Postgres first,
# then revisit worker count.

workers 0

threads_count = Integer(ENV.fetch('PUMA_THREADS', 5))
threads threads_count, threads_count

bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 9292)}"

environment ENV.fetch('APP_ENV', 'production')
