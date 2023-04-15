#!/bin/bash

checkupdate() {
        # get current build id
        CURRENTBUILD=$(docker exec steamcmd grep -i 'buildid' /home/steam/Steam/logs/content_log.txt | tail -n 1 | sed -n 's/^.*BuildID\s\([0-9]\+\).*$/\1/p')

        # get latest build id from steamcmd API
        LATESTBUILD=$(curl -s https://api.steamcmd.net/v1/info/380870 | jq '.["data"]["380870"]["depots"]["branches"]["public"]["buildid"]' | cut -d "\"" -f 2)

        if [ $CURRENTBUILD == $LATESTBUILD ]; then
                logger -p Info -t ZomboidUpdater INFO: "PZserver up2date. Exiting.."
                exit
        else
                :
        fi
}

updater() {
        #0 install ps just in case the container got rebooted
        docker exec steamcmd apt update
        docker exec steamcmd apt install procps -y

        #1 kill pzserver
        for i in $(docker exec steamcmd ps -aux | grep '<SERVERNAME>' | awk '{print $2}'); do docker exec steamcmd kill $i; done

        #2 update pzserver
        docker exec -u steam steamcmd /home/steam/steamcmd/steamcmd.sh +runscript /home/steam/Steam/servers/projectzomboid/update_zomboid.txt

        #3 start pzserver
        docker exec -u steam steamcmd nohup /home/steam/Steam/servers/projectzomboid/start-server.sh -servername <SERVERNAME> &
}

check_availability() {
        # check if pzserver proccesses are running and assign it to the PSTAT variable
        PSTAT=$(docker exec steamcmd ps -aux | grep '<SERVERNAME>' | wc -l)

        # if the NTSTAT variable equals "2" then both of the pzsever ports are open and everything runs as expected
        if [ $PSTAT  == 2 ]; then
                logger -p Info -t ZomboidUpdater SUCCESS: "Processes are UP. PZserver seems to run"
        else
                logger -p Error -t ZomboidUpdater FAILED: "Processes are DOWN. PZserver does not seem to run"
        fi
}

checkupdate
updater
check_availability
