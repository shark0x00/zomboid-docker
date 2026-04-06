# =============================================
# Custom Project Zomboid SteamCMD Image
# Extends cm2network/steamcmd:root and pre-installs procps
# =============================================

FROM cm2network/steamcmd:root

LABEL maintainer="Philipp Fragstein <Philipp.Fragstein@gmx.de>"
LABEL description="SteamCMD with procps for Project Zomboid server"

# Switch to root to install packages
USER root

# Update and install procps (ps, kill, etc.) + clean up to keep image small
RUN apt-get update && \
    apt-get install -y --no-install-recommends procps && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Switch back to steam user (recommended for security and compatibility)
USER steam

# Optional: Create directories if they don't exist yet (helps with volume mounting)
RUN mkdir -p /home/steam/Steam/servers/projectzomboid \
    /home/steam/Steam/logs

# Set working directory
WORKDIR /home/steam

# The actual start command will be provided by your docker-compose.yml
