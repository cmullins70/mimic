#!/usr/bin/env bash
# Start/stop a throwaway sshd for SFTPBackend integration tests.
# Usage: scripts/sftp-test-server.sh start|stop
# Exposes: sftp on localhost:2222, user "mimic", password "mimictest".
set -euo pipefail

NAME=mimic-sftp-test
case "${1:-}" in
  start)
    docker rm -f "$NAME" 2>/dev/null || true
    docker run -d --name "$NAME" -p 2222:22 \
      atmoz/sftp:latest mimic:mimictest:::upload
    echo "Waiting for sshd..."
    for i in $(seq 1 30); do
      if nc -z localhost 2222 2>/dev/null; then echo "ready on localhost:2222"; exit 0; fi
      sleep 1
    done
    echo "sshd did not come up" >&2; exit 1
    ;;
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "stopped"
    ;;
  *)
    echo "usage: $0 start|stop" >&2; exit 2
    ;;
esac
