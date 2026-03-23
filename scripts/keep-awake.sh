#!/usr/bin/env bash
# keep-awake.sh
# Prevents the Mac from sleeping using caffeinate
#
# Usage: ./keep-awake.sh [--duration SECONDS] [--quiet]
# Press Ctrl+C to stop

set -euo pipefail

duration=0  # 0 = indefinite
quiet=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) duration="$2"; shift 2 ;;
        --quiet|-q) quiet=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ "$quiet" != "true" ]]; then
    echo ""
    echo "========================================"
    echo "  KEEP AWAKE - Agent Relay (macOS)"
    echo "========================================"
    echo ""
    echo "This script prevents your Mac from sleeping."
    echo "Using: caffeinate (built-in macOS utility)"
    echo ""
    echo "Press Ctrl+C to stop."
    echo ""
fi

# caffeinate flags:
#   -d  prevent display sleep
#   -i  prevent idle sleep
#   -m  prevent disk sleep
#   -s  prevent system sleep
if [[ "$duration" -gt 0 ]]; then
    if [[ "$quiet" != "true" ]]; then
        echo "Preventing sleep for $duration seconds..."
    fi
    caffeinate -dims -t "$duration" &
    caffeine_pid=$!

    # Show periodic status
    start_time=$(date +%s)
    tick=0
    trap 'kill $caffeine_pid 2>/dev/null; exit 0' INT TERM

    while kill -0 $caffeine_pid 2>/dev/null; do
        tick=$((tick + 1))
        elapsed=$(($(date +%s) - start_time))
        elapsed_str=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))
        if [[ "$quiet" != "true" ]]; then
            timestamp=$(date +"%H:%M:%S")
            echo "[$timestamp] Awake - Running for $elapsed_str (tick #$tick)"
        fi
        sleep 60
    done
else
    # Indefinite - run caffeinate in foreground
    if [[ "$quiet" != "true" ]]; then
        echo "Preventing sleep indefinitely (Ctrl+C to stop)..."
    fi
    caffeinate -dims
fi
