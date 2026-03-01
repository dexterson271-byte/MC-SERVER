FROM eclipse-temurin:21-jre-jammy

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    supervisor \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install FileBrowser for web-based file management (download/upload/backup)
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Create server directory
RUN mkdir -p /data/plugins /data/backups
WORKDIR /data

# Copy config files
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY start.sh /start.sh
COPY filebrowser-config.json /filebrowser-config.json
RUN chmod +x /start.sh

# Default environment variables (override in Railway dashboard)
# Railway Pro: 32GB max per service — 28G for JVM, rest for OS + FileBrowser
ENV MC_VERSION=latest \
    MEMORY=8G \
    SERVER_PORT=25565 \
    FILEBROWSER_PORT=8080 \
    EULA=true \
    SERVER_TYPE=paper \
    DIFFICULTY=normal \
    GAMEMODE=survival \
    MAX_PLAYERS=20 \
    VIEW_DISTANCE=7 \
    SIMULATION_DISTANCE=5 \
    MOTD="A Minecraft Server on Railway"

# Expose ports
EXPOSE ${SERVER_PORT}/tcp
EXPOSE ${FILEBROWSER_PORT}/tcp

# Persistent data lives at /data — attach a Railway Volume mounted to /data

CMD ["/start.sh"]
