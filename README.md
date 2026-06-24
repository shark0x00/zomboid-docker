# zomboid-docker

These files can be used to create and maintain a Project Zomboid server based on docker. 

A comprehensive explanation of the setup can be found under: 
https://blog.stonesec.de/project-zomboid-docker-compose/

## Installation

The initial installation procedure can be found on the PZWIKI page. I followed the installation procedure for steamcmd using the steam user within the docker container:

```
cat >$HOME/update_zomboid.txt <<'EOL'
// update_zomboid.txt
//
@ShutdownOnFailedCommand 1 //set to 0 if updating multiple servers at once
@NoPromptForPassword 1
force_install_dir /opt/pzserver/
//for servers which don't need a login
login anonymous 
app_update 380870 validate
quit
EOL
```

The script needs to be executed afterwards:
```
steamcmd +runscript $HOME/update_zomboid.txt
```

## Auto Update
The `zomboidupdater.sh` script keeps the server in sync with the latest version of Project Zomboid and its Steam Workshop mods. It is designed to run frequently (every 10 minutes via a systemd timer) so that version mismatches between the server and players are caught as quickly as possible.
 
### What it does
 
On every run the script checks the installed game build ID against the Steam API. If no update is available it exits immediately without touching the server. When a game update is detected it will rebuild the custom Docker image, stop the server gracefully, update the base game via SteamCMD, validate all Workshop mods, and bring the server back up.
 
Workshop mods are checked independently of the base game. Even when the game itself has not updated, the script validates all mods configured in the server `.ini` file and compares file modification timestamps before and after. If any mod files changed — meaning SteamCMD actually downloaded something — the server is restarted automatically to load the new version.

Before any action that would stop or restart the server, the script checks whether players are currently connected (see [Player-aware updates](#player-aware-updates-rcon)). If anyone is online the run is deferred and retried on the next timer tick, so an update can never interrupt active gameplay or cause lost progress.
 
### Update flow
 
```
Every 10 minutes
       │
       ▼
 Players connected? (RCON)
       │
      Yes ──► Defer — exit, retry next run
       │
       No ──► Game build ID == Steam API?
                     │
                    Yes ──► Validate workshop mods
                     │              │
                     │         Files changed?
                     │              │
                     │             Yes ──► Re-check players ──► Restart server
                     │              │
                     │              No ──► Exit (nothing to do)
                     │
                     No ──► Rebuild image → Re-check players → Update game → Validate workshop → Restart server
```
 
### Why this approach
 
Project Zomboid updates frequently and mod authors push updates independently of the base game. Running the check every 10 minutes ensures the server stays joinable for players after a Steam update rather than waiting for a nightly cron window. The fast-exit on no update means the check is virtually free — it completes in under two seconds and does not interrupt active gameplay.
 
All output is written to the systemd journal and can be reviewed with:
 
```bash
journalctl -u zomboid-updater -f
```

## Player-aware updates (RCON)

To avoid stopping the server while people are playing, `zomboidupdater.sh` queries the live player count over RCON and **defers the whole run if anyone is connected**. The check runs before the initial work and again immediately before any stop/restart, so a player who joins mid-run is still protected.

Player state is read with [gorcon/rcon-cli](https://github.com/gorcon/rcon-cli), running as a small dedicated container (`rcon.yml`) that is shared across game servers via a common Docker network. One container with one config file (`rcon.yaml`) can serve multiple servers, each addressed by its own environment block.

### Behaviour

| Server state                          | Reported count | Action          |
| ------------------------------------- | -------------- | --------------- |
| Server process not running            | `0`            | Update proceeds |
| Running, `Players connected (0)`      | `0`            | Update proceeds |
| Running, one or more players online   | `N > 0`        | Defer, retry    |
| Running, but RCON unreachable/unparsed| `-1`           | Defer, retry (fail-safe) |

### Prerequisites

Enable RCON in your server `.ini` (e.g. `Server/PZWestSide.ini`) and restart the server once so it listens:

```ini
RCONPort=27015
RCONPassword=ChangeMeToAStrongSecret
```

### Shared network

The rcon container reaches each game server by container name over a shared external network. Create it once:

```bash
docker network create gaming
```

Attach the PZ server to that network in `steamcmd.yml` (add the top-level `networks:` block and a `networks:` key on the service; everything else stays as-is). Optionally publish RCON to localhost on the host for manual testing:

```yaml
networks:
  gaming:
    external: true

services:
  steamcmd:
    # ... existing keys unchanged ...
    ports:
      - "127.0.0.1:27015:27015/tcp"   # optional, host-side testing only
    networks:
      - gaming
```

> A game server must bind RCON on `0.0.0.0` (the Project Zomboid default) for it to be reachable over the shared network. A server bound only to `127.0.0.1` cannot be queried this way.

### rcon-cli config

`rcon.yaml` holds one block per server and is bind-mounted into the rcon container. Keep it out of version control because it contains the RCON password — commit a sanitised `rcon.yaml.example` instead.

```yaml
zomboid:
  address: "steamcmd:27015"          # steamcmd = container_name; port = RCONPort
  password: "ChangeMeToAStrongSecret"
  type: "rcon"
  timeout: "10s"
```

### Bring it up and verify

```bash
docker compose -f /root/gaming/steamcmd.yml up -d   # recreate so it joins 'gaming'
docker compose -f /root/gaming/rcon.yml up -d
docker exec rcon /rcon -c /rcon.yaml -e zomboid players
# -> "Players connected (0):"
```

### Updater configuration

The updater selects which server to query via two variables near the top of `zomboidupdater.sh`:

```bash
RCON_CONTAINER="rcon"     # container_name from rcon.yml
RCON_ENV="zomboid"        # environment block in rcon.yaml
```

Deferrals are logged to the journal alongside the rest of the run:

```bash
journalctl -u zomboid-updater -f
# ... Update deferred: 1 player(s) online (pre-check)
```