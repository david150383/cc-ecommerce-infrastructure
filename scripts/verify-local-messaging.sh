#!/usr/bin/env bash
# Kept for existing docs and workflows: the check now uses probe queues (safe while services run).
exec python3 -u "$(dirname "$0")/verify-local-messaging.py" "$@"
