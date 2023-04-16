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
The automatic update ist conducted from outside the container. The "pzautoupdate.sh" needs to be stored under /etc/cron.hourly for this purpose. 
