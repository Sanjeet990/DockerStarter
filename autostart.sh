#!/bin/sh
# Start containers with label org.starter.autostart=true
#
# LABELS:
#   org.starter.autostart=true          — include this container
#   org.starter.depends_on=name1,name2  — start these containers first (dep ordering)
#   org.starter.order=10                — explicit start order (lower = earlier); no label = started last
#   org.starter.wait_for_port=5432      — wait for this TCP port to be open before the
#                                         next container in sequence is considered ready
#
# USAGE:
#   sh autostart.sh
#   ./autostart.sh          (requires execute bit: chmod +x autostart.sh)

BATCH_SIZE=5
PORT_WAIT_TIMEOUT=60   # seconds to wait for a port before giving up

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

get_label() {
  docker inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null
}

get_name() {
  docker inspect --format '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'
}

get_state() {
  docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null
}


# ── Port waiting ──────────────────────────────────────────────────────────────
# Usage: wait_for_port <name> <host> <port>
# Probes host:port via nc (or /dev/tcp fallback) until open or timeout.
# Called BEFORE starting the container that needs the port.

wait_for_port() {
  name=$1
  host=$2
  port=$3

  info "[$name] Waiting for $host:$port to be open (timeout: ${PORT_WAIT_TIMEOUT}s)..."

  elapsed=0
  while [ "$elapsed" -lt "$PORT_WAIT_TIMEOUT" ]; do
    if command -v nc >/dev/null 2>&1; then
      nc -z "$host" "$port" >/dev/null 2>&1 && break
    elif (echo > /dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [ "$elapsed" -ge "$PORT_WAIT_TIMEOUT" ]; then
    warn "[$name] Timed out waiting for $host:$port — starting anyway."
  else
    info "[$name] $host:$port is open (after ${elapsed}s)."
  fi
}

# ── Start a single container (skip if already running) ────────────────────────

start_one() {
  id=$1
  name=$(get_name "$id")
  state=$(get_state "$id")

  if [ "$state" = "running" ]; then
    info "[$name] Already running — skipping."
    return 0
  fi

  # If this container has wait_for_port, probe that port BEFORE starting it.
  # Format: <port>  or  <host>:<port>  (host defaults to 127.0.0.1)
  port_label=$(get_label "$id" "org.starter.wait_for_port")
  if [ -n "$port_label" ]; then
    case "$port_label" in
      *:*) wfp_host=${port_label%%:*}; wfp_port=${port_label##*:} ;;
      *)   wfp_host="127.0.0.1";      wfp_port=$port_label ;;
    esac
    wait_for_port "$name" "$wfp_host" "$wfp_port"
  fi

  info "[$name] Starting..."
  if docker start "$id" >/dev/null; then
    info "[$name] Started."
  else
    err "[$name] Failed to start!"
  fi
}

# ── Batch runner ──────────────────────────────────────────────────────────────
# Reads container IDs from a file and starts them BATCH_SIZE at a time.
# Within each batch containers start in parallel; batches are sequential.
# Containers with wait_for_port must run sequentially — they block BEFORE
# docker start until the required port is open, so backgrounding them would
# defeat the purpose.

start_in_batches() {
  ids_file=$1
  total=$(wc -l < "$ids_file" | tr -d ' ')
  batch_num=0
  i=0

  while IFS= read -r id; do
    [ -z "$id" ] && continue

    # ── New batch boundary ──
    if [ $((i % BATCH_SIZE)) -eq 0 ]; then
      if [ "$i" -gt 0 ]; then
        wait
        info "── Batch $batch_num complete ──"
        echo
      fi
      batch_num=$((batch_num + 1))
      end=$(( i + BATCH_SIZE < total ? i + BATCH_SIZE : total ))
      info "── Batch $batch_num: containers $((i+1))–${end} of $total ──"
    fi

    # Containers with wait_for_port must run in the foreground so the next
    # container only starts after the port is confirmed open.
    port=$(get_label "$id" "org.starter.wait_for_port")
    if [ -n "$port" ]; then
      # Flush any parallel jobs in flight before this sequential step
      wait
      start_one "$id"
    else
      start_one "$id" &
    fi

    i=$((i + 1))
  done < "$ids_file"

  wait
  [ "$batch_num" -gt 0 ] && info "── Batch $batch_num complete ──"
}

# ── Build ordered ID list ─────────────────────────────────────────────────────
# Order of precedence (most significant first):
#   1. Topological sort on depends_on edges (dependencies always come first)
#   2. org.starter.order label (numeric, lower = earlier)
#   3. Containers with no order label are placed after all ordered ones

build_ordered_ids() {
  out_file=$1

  tmp_dir=$(mktemp -d)
  # POSIX trap — runs on function return via subshell trick below
  ids_file="$tmp_dir/ids"
  names_file="$tmp_dir/names"
  deps_file="$tmp_dir/deps"
  indegree_file="$tmp_dir/indegree"
  order_file="$tmp_dir/order"     # id<TAB>numeric_order

  # ── Collect candidates ────────────────────────────────────────────────────
  docker ps -a \
    --filter "label=org.starter.autostart=true" \
    --format "{{.ID}}" > "$ids_file"

  if [ ! -s "$ids_file" ]; then
    info "No containers found with label org.starter.autostart=true."
    rm -rf "$tmp_dir"
    exit 0
  fi

  # Build names map, in-degree table, and order table
  while IFS= read -r id; do
    name=$(get_name "$id")
    printf '%s\t%s\n' "$id" "$name" >> "$names_file"
    printf '%s\t0\n'  "$id"         >> "$indegree_file"

    ord=$(get_label "$id" "org.starter.order")
    # Containers without an order get a very high number so they sort last
    if [ -z "$ord" ] || ! echo "$ord" | grep -qE '^[0-9]+$'; then
      ord=999999
    fi
    printf '%s\t%s\n' "$id" "$ord" >> "$order_file"
  done < "$ids_file"

  touch "$deps_file"

  # ── Parse depends_on edges ────────────────────────────────────────────────
  while IFS= read -r id; do
    raw_deps=$(get_label "$id" "org.starter.depends_on")
    [ -z "$raw_deps" ] && continue

    echo "$raw_deps" | tr ',' '\n' | while IFS= read -r dep_name; do
      dep_name=$(echo "$dep_name" | tr -d '[:space:]')
      [ -z "$dep_name" ] && continue

      dep_id=$(awk -F'\t' -v n="$dep_name" '$2==n{print $1}' "$names_file")

      if [ -z "$dep_id" ]; then
        my_name=$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$names_file")
        warn "Dependency '$dep_name' for '$my_name' not found — ignoring."
        continue
      fi

      printf '%s\t%s\n' "$id" "$dep_id" >> "$deps_file"

      # Increment in-degree of the dependent container
      cur=$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$indegree_file")
      tmpf=$(mktemp "$tmp_dir/indeg.XXXXXX")
      awk -F'\t' -v i="$id" -v c="$((cur+1))" \
        'BEGIN{OFS="\t"} $1==i{$2=c} {print}' "$indegree_file" > "$tmpf"
      mv "$tmpf" "$indegree_file"
    done
  done < "$ids_file"

  # ── Kahn's BFS — but seed queue sorted by org.starter.order ──────────────
  queue_file="$tmp_dir/queue"
  sorted_file="$tmp_dir/sorted"
  touch "$sorted_file"

  # Seed: all nodes with in-degree 0, sorted by their order value
  awk -F'\t' '$2==0{print $1}' "$indegree_file" | while IFS= read -r id; do
    ord=$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$order_file")
    printf '%s\t%s\n' "$ord" "$id"
  done | sort -t'	' -k1,1n | awk -F'\t' '{print $2}' > "$queue_file"

  while [ -s "$queue_file" ]; do
    node=$(head -n1 "$queue_file")
    tmpf=$(mktemp "$tmp_dir/queue.XXXXXX")
    tail -n +2 "$queue_file" > "$tmpf" && mv "$tmpf" "$queue_file"

    echo "$node" >> "$sorted_file"

    # For each container that depends on $node, decrement in-degree
    # When it hits 0, insert into queue in order-sorted position
    awk -F'\t' -v n="$node" '$2==n{print $1}' "$deps_file" | while IFS= read -r dependent; do
      cur=$(awk -F'\t' -v i="$dependent" '$1==i{print $2}' "$indegree_file")
      new_deg=$((cur - 1))
      tmpf2=$(mktemp "$tmp_dir/indeg.XXXXXX")
      awk -F'\t' -v i="$dependent" -v c="$new_deg" \
        'BEGIN{OFS="\t"} $1==i{$2=c} {print}' "$indegree_file" > "$tmpf2"
      mv "$tmpf2" "$indegree_file"

      if [ "$new_deg" -eq 0 ]; then
        ord=$(awk -F'\t' -v i="$dependent" '$1==i{print $2}' "$order_file")
        # Merge into queue maintaining sort order
        tmpq=$(mktemp "$tmp_dir/queue.XXXXXX")
        printf '%s\t%s\n' "$ord" "$dependent" >> "$queue_file"
        sort -t'	' -k1,1n "$queue_file" | awk -F'\t' '{print $2}' > "$tmpq"
        mv "$tmpq" "$queue_file"
      fi
    done
  done

  # ── Cycle detection ───────────────────────────────────────────────────────
  sorted_count=$(wc -l < "$sorted_file" | tr -d ' ')
  total_count=$(wc -l < "$ids_file"     | tr -d ' ')

  if [ "$sorted_count" -ne "$total_count" ]; then
    err "Cycle detected in container dependencies! Falling back to order-label sort only."
    # Fallback: just sort all IDs by their order label
    while IFS= read -r id; do
      ord=$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$order_file")
      printf '%s\t%s\n' "$ord" "$id"
    done < "$ids_file" | sort -t'	' -k1,1n | awk -F'\t' '{print $2}' > "$out_file"
  else
    cp "$sorted_file" "$out_file"
  fi

  rm -rf "$tmp_dir"
}

# ── Main ──────────────────────────────────────────────────────────────────────

info "=== Docker Autostart ==="
echo

SORTED_IDS=$(mktemp)
# Cleanup on exit — POSIX compatible
trap 'rm -f "$SORTED_IDS"' EXIT INT TERM

build_ordered_ids "$SORTED_IDS"

total=$(wc -l < "$SORTED_IDS" | tr -d ' ')
info "Found $total container(s) to process."
echo

start_in_batches "$SORTED_IDS"

echo
info "=== Done ==="
