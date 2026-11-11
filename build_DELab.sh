#!/bin/bash
# =============================================================
# build_delab.sh  -  Phases 1 to 3: get the files + build Stages 2-4
#
# Covers:
#   Phase 1  - clone the DELab repo into ~/setu
#   Phase 2  - build Stage 2 -> 3 -> 4 (deploy + validate each)
#   Phase 3  - confirm everything is up + print login details
#
# Does NOT cover:
#   Phase 0  - installing Docker Desktop (do that by hand first)
#   Phase 4  - adding the techsupport account (run 01_setup_endpoint.sh after)
#
# RUN IN THE MAC TERMINAL (bash/zsh is fine). Docker Desktop must be running.
# First run is SLOW: the cold Wazuh build takes 10-20 minutes. Be patient.
# =============================================================

set -e
REPO_URL="https://github.com/micksetu/DELab.git"
REPO_PARENT="$HOME/setu"

say() { echo ""; echo "============================================================"; echo ">>> $*"; echo "============================================================"; }

# ---- Pre-flight: Docker running? ----
say "Checking Docker is installed and running"
docker version         >/dev/null || { echo "ERROR: Docker isn't running. Start Docker Desktop, then re-run."; exit 1; }
docker compose version >/dev/null || { echo "ERROR: 'docker compose' not available."; exit 1; }
echo "Docker OK."

# ---- PHASE 1: get the files ----
say "PHASE 1 - Getting the DELab files into ~/setu"

# ~/setu: create only if missing (mkdir -p is a no-op if it already exists)
if [ ! -d "$REPO_PARENT" ]; then
  echo "Creating $REPO_PARENT"
  mkdir -p "$REPO_PARENT"
else
  echo "$REPO_PARENT already exists - using it."
fi
cd "$REPO_PARENT"

# DELab: if it's already a git clone, pull latest; otherwise clone it.
if [ -d "DELab/.git" ]; then
  echo "DELab already cloned - pulling latest changes..."
  git -C DELab pull --ff-only || echo "WARN: pull failed (local changes?) - continuing with existing copy."
elif [ -d "DELab" ]; then
  echo "A 'DELab' folder exists but isn't a git clone - using it as-is."
else
  echo "Cloning DELab..."
  git clone "$REPO_URL"
fi

cd DELab
chmod +x stage-*/*.sh || true
echo "Repo ready at: $REPO_PARENT/DELab"

DELAB_ROOT="$REPO_PARENT/DELab"
set +e      # from here, handle errors ourselves (don't abort on a failed validate)

# ---- PHASE 1b: clean up any OLD DELab containers/volumes (DELab only) ----
# This removes leftovers from a previous/failed build so Stage 2 starts clean.
# It only touches DELab resources (compose projects + delab-/wazuh/velociraptor
# containers) - your other Docker containers and images are NOT affected.
# Images are kept by default (faster rebuild). Pass --clean-images to drop them too.
say "PHASE 1b - Cleaning up any old DELab containers (DELab only)"

# 1) bring down each stage's compose project (removes its containers + volumes)
for d in stage-4-investigation stage-3-detections stage-2-eyes; do
  if [ -d "$DELAB_ROOT/$d" ]; then
    ( cd "$DELAB_ROOT/$d" && docker compose down -v --remove-orphans ) 2>/dev/null
  fi
done

# 2) force-remove any lingering DELab containers by name (safety net)
OLD=$(docker ps -aq --filter "name=delab" --filter "name=wazuh" --filter "name=velociraptor")
if [ -n "$OLD" ]; then
  echo "Removing leftover containers: $(docker ps -a --format '{{.Names}}' --filter name=delab --filter name=wazuh --filter name=velociraptor | tr '\n' ' ')"
  docker rm -f $OLD >/dev/null 2>&1
else
  echo "No leftover DELab containers found."
fi

# 3) optional: also delete DELab images (only if you pass --clean-images)
if [ "$1" = "--clean-images" ]; then
  echo "Removing DELab-related images (forces a full rebuild)..."
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
    | grep -Ei 'delab|wazuh|velociraptor' | awk '{print $2}' | sort -u \
    | xargs -r docker rmi -f >/dev/null 2>&1
fi
echo "Cleanup done."

# ---- PHASE 2: build the stages ----
# Note: validate.sh can FAIL transiently right after deploy, because the Wazuh
# agent takes up to a minute to connect. So we retry validate once after a wait,
# and even if it still fails we CONTINUE (you can re-run validate later).

run_stage() {
  local dir="$1"
  local path="$DELAB_ROOT/$dir"
  if [ ! -d "$path" ]; then
    echo "ERROR: stage folder not found: $path  (skipping)"; return 1
  fi
  cd "$path"                       # absolute path - never strands us
  ./deploy.sh
  if ! ./validate.sh; then
    echo ">>> validate failed - waiting 60s for the agent to connect, then retrying once..."
    sleep 60
    ./validate.sh || echo ">>> WARN: $dir validate still failing. Build continues; re-run './validate.sh' in $dir later."
  fi
  cd "$DELAB_ROOT"                  # always return to the repo root
}

say "PHASE 2a - STAGE 2 (Wazuh monitoring) - the slow 10-20 min build"
run_stage stage-2-eyes

say "PHASE 2b - STAGE 3 (custom detection rule)"
run_stage stage-3-detections

say "PHASE 2c - STAGE 4 (Velociraptor investigation)"
run_stage stage-4-investigation

# ---- PHASE 3: confirm + access details ----
say "PHASE 3 - BUILD COMPLETE - what's running now"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

cat <<'INFO'

------------------------------------------------------------
ACCESS DETAILS
------------------------------------------------------------
Wazuh dashboard : https://localhost:443    admin / SecretPassword
Velociraptor    : https://localhost:8889   admin / VelociraptorLab123!
(click through the self-signed certificate warning in the browser)

Endpoint 10.10.10.10 (delab-endpoint) · Attacker delab-attacker

NEXT (Phase 4) - add the techsupport demo account:
  docker cp 01_setup_endpoint.sh delab-endpoint:/tmp/
  docker cp 03_privesc_setup.sh  delab-endpoint:/tmp/
  docker exec -it delab-endpoint bash
  bash /tmp/01_setup_endpoint.sh
  exit
Then follow Part2_DEMO_Steps.md.

RESET everything (from any stage folder):  ./reset.sh
------------------------------------------------------------
INFO

echo ""
echo "Done. If a stage failed above, scroll to the first ERROR, re-run that stage's"
echo "./deploy.sh (safe to re-run), then re-run this script."
