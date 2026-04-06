#!/bin/bash
# Project Zomboid Updater — game + workshop checked independently
# Restarts server if either game OR workshop mods were updated

set -euo pipefail

CONTAINER_NAME="steamcmd"
COMPOSE_FILE="/root/gaming/steamcmd.yml"
DOCKERFILE_DIR="/root/gaming"
SERVERNAME="PZWestSide"
PZ_APPID="380870"
PZ_WORKSHOP_GAMEID="108600"
WORKSHOP_DIR="/home/steam/Steam/steamapps/workshop/content/${PZ_WORKSHOP_GAMEID}"

GAME_UPDATE_NEEDED=false
WORKSHOP_UPDATE_DETECTED=false

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── 1. Check if game update is available ─────────────────────────────────────
check_game_update() {
    log "Checking Project Zomboid build ID..."

    CURRENTBUILD=$(docker exec "$CONTAINER_NAME" \
        grep -oP '"buildid"\s+"\K[0-9]+' \
        /home/steam/Steam/servers/projectzomboid/steamapps/appmanifest_${PZ_APPID}.acf \
        2>/dev/null || echo "0")

    LATESTBUILD=$(curl -s --max-time 10 \
        "https://api.steamcmd.net/v1/info/${PZ_APPID}" | \
        jq -r '.data["'"${PZ_APPID}"'"].depots.branches.public.buildid // "0"')

    log "Installed build : $CURRENTBUILD"
    log "Latest build    : $LATESTBUILD"

    if [ "$CURRENTBUILD" = "$LATESTBUILD" ]; then
        log "→ Game is up to date."
        GAME_UPDATE_NEEDED=false
    else
        log "→ Game update detected: $CURRENTBUILD → $LATESTBUILD"
        GAME_UPDATE_NEEDED=true
    fi
}

# ── 2. Snapshot workshop mod mtimes before update ────────────────────────────
snapshot_workshop() {
    log "Taking workshop mod snapshot (pre-update)..."

    # For each mod folder, record its newest file mtime as a single checksum-like string
    SNAPSHOT_BEFORE=$(docker exec "$CONTAINER_NAME" \
        find "$WORKSHOP_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort | md5sum || echo "none")

    log "Pre-update snapshot taken."
}

# ── 3. Run workshop validate, then compare snapshot ──────────────────────────
update_workshop() {
    log "=== Validating workshop mods ==="

    CONFIG_FILE="/home/steam/Zomboid/Server/${SERVERNAME}.ini"

    if ! docker exec "$CONTAINER_NAME" test -f "$CONFIG_FILE" 2>/dev/null; then
        log "WARNING: Config not found at $CONFIG_FILE — skipping workshop."
        return
    fi

    MOD_IDS=$(docker exec "$CONTAINER_NAME" \
        sed -n 's/^WorkshopItems=\(.*\)/\1/p' "$CONFIG_FILE" | \
        tr ';' '\n' | grep -v '^$' || true)

    if [ -z "$MOD_IDS" ]; then
        log "→ No workshop mods configured."
        return
    fi

    MOD_COUNT=$(echo "$MOD_IDS" | wc -l)
    log "Found $MOD_COUNT mod(s). Running validate..."

    # Build single batched SteamCMD call for all mods
    STEAMCMD_ARGS="+login anonymous"
    while IFS= read -r id; do
        [ -n "$id" ] && STEAMCMD_ARGS+=" +workshop_download_item $PZ_WORKSHOP_GAMEID $id validate"
    done <<< "$MOD_IDS"
    STEAMCMD_ARGS+=" +quit"

    # shellcheck disable=SC2086
    if docker exec -u steam "$CONTAINER_NAME" \
        /home/steam/steamcmd/steamcmd.sh $STEAMCMD_ARGS; then
        log "→ Workshop validate completed."
    else
        log "WARNING: SteamCMD returned non-zero — check output above."
    fi

    # Compare snapshot after validate
    log "Comparing workshop state post-validate..."
    SNAPSHOT_AFTER=$(docker exec "$CONTAINER_NAME" \
        find "$WORKSHOP_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort | md5sum || echo "none")

    if [ "$SNAPSHOT_BEFORE" != "$SNAPSHOT_AFTER" ]; then
        log "→ Workshop mods changed — restart required."
        WORKSHOP_UPDATE_DETECTED=true
        logger -p info -t zomboid-updater "Workshop mods updated — server restart triggered"
    else
        log "→ No workshop changes detected."
        WORKSHOP_UPDATE_DETECTED=false
    fi
}

# ── 4. Rebuild the custom Docker image ───────────────────────────────────────
rebuild_image() {
    log "Pulling latest base image and rebuilding pz-steamcmd:custom..."
    docker pull cm2network/steamcmd:root
    docker build --no-cache -t pz-steamcmd:custom "$DOCKERFILE_DIR"
}

# ── 5. Stop server gracefully ────────────────────────────────────────────────
stop_server() {
    log "Stopping PZ server (SIGTERM → 10s flush → container stop)..."
    for pid in $(docker exec "$CONTAINER_NAME" \
        ps -aux 2>/dev/null | \
        grep -E 'PZWestSide|ProjectZomboid64' | \
        grep -v grep | awk '{print $2}' || true); do
        docker exec "$CONTAINER_NAME" kill -15 "$pid" 2>/dev/null || true
    done
    sleep 10
    docker compose -f "$COMPOSE_FILE" stop steamcmd
    sleep 3
}

# ── 6. Start container in maintenance mode (no PZ process) ───────────────────
start_maintenance_container() {
    log "Starting maintenance container..."
    docker compose -f "$COMPOSE_FILE" up -d steamcmd

    for i in $(seq 1 15); do
        docker exec "$CONTAINER_NAME" true 2>/dev/null && { log "Container ready."; return; }
        sleep 2
    done
    log "ERROR: Container did not become ready in time." >&2
    exit 1
}

# ── 7. Update PZ base game via SteamCMD ──────────────────────────────────────
update_game() {
    log "Updating Project Zomboid base game..."
    docker exec -u steam "$CONTAINER_NAME" \
        /home/steam/steamcmd/steamcmd.sh \
        +runscript /home/steam/Steam/servers/projectzomboid/update_zomboid.txt
    log "Game update complete."
}

# ── 8. Restart into game server mode and verify ──────────────────────────────
restart_server() {
    log "Restarting into game server mode..."
    docker compose -f "$COMPOSE_FILE" stop steamcmd
    sleep 3
    docker compose -f "$COMPOSE_FILE" up -d steamcmd

    log "Waiting for PZ server process (up to 90s)..."
    for i in $(seq 1 18); do
        PSTAT=$(docker exec "$CONTAINER_NAME" \
            ps -aux 2>/dev/null | \
            grep -E 'PZWestSide|ProjectZomboid64' | \
            grep -v grep | wc -l || echo "0")
        if [ "$PSTAT" -ge 1 ]; then
            log "SUCCESS: PZ server process is running."
            logger -p info -t zomboid-updater "Server restarted successfully after update"
            return
        fi
        sleep 5
    done
    log "FAILED: Server process not detected after 90s — check logs!"
    logger -p err -t zomboid-updater "Server failed to start after update"
}

# ══════════════════════════════ MAIN ══════════════════════════════════════════
log "========== Zomboid Update Check Start =========="

check_game_update

if [ "$GAME_UPDATE_NEEDED" = true ]; then
    # Full update path: rebuild image, update game + workshop, restart
    log "--- Game update required ---"
    rebuild_image
    stop_server
    start_maintenance_container
    update_game
    snapshot_workshop
    update_workshop
    restart_server

else
    # No game update — still check workshop mods independently
    log "--- Game up to date — checking workshop mods ---"
    snapshot_workshop
    update_workshop

    if [ "$WORKSHOP_UPDATE_DETECTED" = true ]; then
        log "--- Workshop changes require server restart ---"
        stop_server
        start_maintenance_container
        restart_server
    else
        log "--- Nothing to do. Server untouched. ---"
    fi
fi

log "========== Done =========="
