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
The zomboidupdater.sh script keeps the server in sync with the latest version of Project Zomboid and its Steam Workshop mods. It is designed to run frequently (every 10 minutes via a systemd timer) so that version mismatches between the server and players are caught as quickly as possible.
What it does
On every run the script checks the installed game build ID against the Steam API. If no update is available it exits immediately without touching the server. When a game update is detected it will rebuild the custom Docker image, stop the server gracefully, update the base game via SteamCMD, validate all Workshop mods, and bring the server back up.
Workshop mods are checked independently of the base game. Even when the game itself has not updated, the script validates all mods configured in the server .ini file and compares file modification timestamps before and after. If any mod files changed — meaning SteamCMD actually downloaded something — the server is restarted automatically to load the new version.
Update flow
Every 10 minutes
       │
       ▼
 Game build ID == Steam API?
       │
      Yes ──► Validate workshop mods
       │              │
       │         Files changed?
       │              │
       │             Yes ──► Restart server
       │              │
       │              No ──► Exit (nothing to do)
       │
       No ──► Rebuild image → Update game → Validate workshop → Restart server
Why this approach
Project Zomboid updates frequently and mod authors push updates independently of the base game. Running the check every 10 minutes ensures the server stays joinable for players after a Steam update rather than waiting for a nightly cron window. The fast-exit on no update means the check is virtually free — it completes in under two seconds and does not interrupt active gameplay.
All output is written to the systemd journal and can be reviewed with:
bashjournalctl -u zomboid-updater -f
