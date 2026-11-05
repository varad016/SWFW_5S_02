#!/usr/bin/env bash
# ==============================================================================
# Host GitOps Reconciler
# Continuously reconciles deploy stack against origin/main.
# - Skips reconciliation while chaos tests are active (/tmp/.chaos-active exists)
# - Detects and pulls new commits from origin/main
# - Detects and reverts manual configuration drift (git reset --hard)
# - Triggers docker compose up -d only upon state change (drift or new commit)
# - Designed to run strictly in the deployment clone (~/deploy/SWFW_5S_02)
# ==============================================================================

set -eu

DEV_DIR="/home/varad/SWFW_5S_02"
CURRENT_DIR="$(pwd -P)"
CHAOS_FLAG="${CHAOS_ACTIVE_FILE:-/tmp/.chaos-active}"
POLL_INTERVAL="${RECONCILER_INTERVAL:-5}"
BRANCH="${RECONCILER_BRANCH:-main}"
ONCE_MODE=false

if [ "${1:-}" = "--once" ]; then
  ONCE_MODE=true
fi

# Safety check: Prevent running inside the developer working tree
if [ "${CURRENT_DIR}" = "${DEV_DIR}" ]; then
  echo "[ERROR] Refusing to run in dev working tree (${DEV_DIR})."
  echo "The GitOps reconciler must run strictly from the deploy clone (~/deploy/SWFW_5S_02)."
  exit 1
fi

if [ ! -d ".git" ]; then
  echo "[ERROR] Not a git repository: ${CURRENT_DIR}"
  exit 1
fi

if [ ! -f ".env" ]; then
  echo "[WARN] No .env file found in deploy clone. Generating from .env.example..."
  cp .env.example .env
fi

echo "=================================================================="
echo "== GitOps Continuous Reconciler Active                          =="
echo "   Deploy Directory : ${CURRENT_DIR}"
echo "   Target Branch    : origin/${BRANCH}"
echo "   Chaos Flag Path  : ${CHAOS_FLAG}"
echo "   Poll Interval    : ${POLL_INTERVAL}s"
echo "   Execution Mode   : $([ "${ONCE_MODE}" = true ] && echo "One-shot" || echo "Continuous Loop")"
echo "=================================================================="

reconcile_step() {
  # 1. Check for active chaos testing
  if [ -f "${CHAOS_FLAG}" ]; then
    echo "[GITOPS] [$(date +%T)] Chaos flag active (${CHAOS_FLAG}). Reconciler paused to preserve experiment state."
    return 0
  fi

  # 2. Check for configuration drift (untracked/uncommitted changes)
  # Exclude runtime gitignored files (.env, volumes/, nginx.conf)
  drift=$(git status --porcelain)
  drift_reverted=false
  if [ -n "${drift}" ]; then
    echo "[GITOPS] [$(date +%T)] Configuration drift detected in deployment tree:"
    echo "${drift}"
    echo "[GITOPS] Reverting manual modifications to enforce declared Git state..."
    git checkout -- .
    git clean -fd -e .env -e volumes/ -e config/global/nginx.conf
    drift_reverted=true
    echo "[GITOPS] Drift successfully reverted."
  fi

  # 3. Check for new upstream commits from origin
  git fetch origin "${BRANCH}" --quiet || {
    echo "[WARN] [$(date +%T)] git fetch failed (remote unreachable). Will retry next cycle."
    return 0
  }

  LOCAL_HASH=$(git rev-parse HEAD)
  REMOTE_HASH=$(git rev-parse "origin/${BRANCH}")

  if [ "${LOCAL_HASH}" != "${REMOTE_HASH}" ] || [ "${drift_reverted}" = true ]; then
    if [ "${LOCAL_HASH}" != "${REMOTE_HASH}" ]; then
      echo "[GITOPS] [$(date +%T)] New commit detected upstream: ${LOCAL_HASH:0:8} -> ${REMOTE_HASH:0:8}"
      echo "[GITOPS] Pulling latest changes from origin/${BRANCH}..."
      git merge --ff-only "origin/${BRANCH}"
    fi

    echo "[GITOPS] Reconciling Docker Compose services to match desired state..."
    docker compose --profile all up -d --remove-orphans
    echo "[GITOPS] [$(date +%T)] Reconciliation complete. System state is synchronized with origin/${BRANCH}."
  else
    # In-sync heartbeat
    return 0
  fi
}

if [ "${ONCE_MODE}" = true ]; then
  reconcile_step
  exit 0
fi

while true; do
  reconcile_step
  sleep "${POLL_INTERVAL}"
done
