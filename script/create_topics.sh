#!/usr/bin/env bash
# Creates the four match topics (docs/architecture.md §6).
#
# Partition count is fixed at 12 and must stay that way: key -> partition mapping is
# only stable at a fixed partition count, so raising it later would reshuffle which
# runner owns which in-flight match.
#
# Safe to re-run; existing topics are left alone.

set -euo pipefail

PARTITIONS="${PARTITIONS:-12}"
RETENTION_MS="${RETENTION_MS:-604800000}" # 7 days
RPK=(docker compose exec -T redpanda rpk)

create() {
  local topic="$1"; shift
  if "${RPK[@]}" topic describe "$topic" >/dev/null 2>&1; then
    echo "  = $topic (exists)"
  else
    "${RPK[@]}" topic create "$topic" --partitions "$PARTITIONS" "$@" >/dev/null
    echo "  + $topic"
  fi
}

echo "Creating topics with $PARTITIONS partitions..."

# Player intent. Read by the match-runners consumer group; partition assignment is
# what makes exactly-one-runner-per-match a Kafka invariant rather than our code.
create match.commands  --topic-config "retention.ms=$RETENTION_MS"

# Engine output: ticks, incidents, production. Fanned out to egress consumers.
create match.events    --topic-config "retention.ms=$RETENTION_MS"

# Latest full state per match. Compacted, so recovery is "read the newest value for
# this key" — each record carries the command offset it was taken at.
create match.snapshots --topic-config "cleanup.policy=compact" \
                       --topic-config "min.cleanable.dirty.ratio=0.1"

# created / started / ended.
create match.lifecycle --topic-config "retention.ms=$RETENTION_MS"

echo
"${RPK[@]}" topic list
