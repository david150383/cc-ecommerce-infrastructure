#!/usr/bin/env bash
# Creates the GitHub repositories and pushes each local repo independently.
# Requires: GitHub CLI (`brew install gh`, then `gh auth login`).
# Usage: scripts/create-github-repos.sh <github-owner> [--public]
# ecommerce-contracts is intentionally NOT created here (Phase 6).
set -euo pipefail

OWNER="${1:?usage: $0 <github-owner> [--public]}"
VISIBILITY="${2:---private}"
WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"

REPOS=(
  ecommerce-auth-service
  ecommerce-product-service
  ecommerce-inventory-service
  ecommerce-order-service
  ecommerce-saga-orchestrator
  ecommerce-payment-service
  ecommerce-notification-service
  ecommerce-frontend
  ecommerce-infrastructure
)

for repo in "${REPOS[@]}"; do
  dir="$WORKSPACE/$repo"
  if [[ ! -d "$dir/.git" ]]; then
    echo "skip: $dir is not a git repository" >&2
    continue
  fi
  echo "==> $OWNER/$repo"
  if gh repo view "$OWNER/$repo" >/dev/null 2>&1; then
    echo "    already exists on GitHub"
  else
    gh repo create "$OWNER/$repo" "$VISIBILITY" --source "$dir" --remote origin
  fi
  git -C "$dir" push -u origin main
done
