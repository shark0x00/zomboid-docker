# zomboid-docker

Full installation instructions can be found under: 
https://blog.stonesec.de/project-zomboid-docker-compose/

## Installation

The initial installation procedure can be found on the PZWIKI page. I followed the installation procedure for steamcmd using the steam user:

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

```
steamcmd +runscript $HOME/update_zomboid.txt
```

## Auto Update
Put the "pzautoupdate.sh" under /etc/cron.hourly of the host system.
