#!/bin/bash
set -e

cd /data

# ─── Get all available PaperMC versions ───
get_available_versions() {
    curl -s https://api.papermc.io/v2/projects/paper | jq -r '.versions[]'
}

# ─── Download PaperMC if not present or version changed ───
download_paper() {
    echo "==> Fetching PaperMC version info..."

    # Get all available versions
    AVAILABLE_VERSIONS=$(get_available_versions)
    echo "==> Available 1.21.x versions:"
    echo "$AVAILABLE_VERSIONS" | grep "^1\.21" | tr '\n' ', '
    echo ""

    if [ "$MC_VERSION" = "latest" ]; then
        MC_VERSION=$(echo "$AVAILABLE_VERSIONS" | tail -1)
        echo "==> Using latest version: $MC_VERSION"
    else
        # Check if the requested version exists
        if echo "$AVAILABLE_VERSIONS" | grep -qx "$MC_VERSION"; then
            echo "==> Requested version $MC_VERSION is available!"
        else
            echo "==> WARNING: Version $MC_VERSION not found on PaperMC!"
            echo "==> Available versions:"
            echo "$AVAILABLE_VERSIONS" | tail -20
            # Try to find closest match (e.g. if user asks for 1.21.10, find closest 1.21.x)
            MAJOR_MINOR=$(echo "$MC_VERSION" | grep -oP '^\d+\.\d+')
            CLOSEST=$(echo "$AVAILABLE_VERSIONS" | grep "^${MAJOR_MINOR}" | tail -1)
            if [ -n "$CLOSEST" ]; then
                echo "==> Falling back to closest available version: $CLOSEST"
                MC_VERSION="$CLOSEST"
            else
                echo "==> ERROR: No ${MAJOR_MINOR}.x versions available. Using latest."
                MC_VERSION=$(echo "$AVAILABLE_VERSIONS" | tail -1)
            fi
        fi
    fi

    BUILD=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION/builds" | jq -r '.builds[-1].build')

    if [ "$BUILD" = "null" ] || [ -z "$BUILD" ]; then
        echo "==> ERROR: Could not fetch builds for $MC_VERSION"
        exit 1
    fi

    DOWNLOAD_NAME="paper-${MC_VERSION}-${BUILD}.jar"
    DOWNLOAD_URL="https://api.papermc.io/v2/projects/paper/versions/$MC_VERSION/builds/$BUILD/downloads/$DOWNLOAD_NAME"

    if [ ! -f "paper.jar" ] || [ "$(cat .paper-version 2>/dev/null)" != "$DOWNLOAD_NAME" ]; then
        echo "==> Downloading PaperMC $MC_VERSION build $BUILD..."
        wget -q -O paper.jar "$DOWNLOAD_URL"
        echo "$DOWNLOAD_NAME" > .paper-version
        echo "==> Download complete!"
    else
        echo "==> PaperMC is up to date ($DOWNLOAD_NAME)"
    fi
}

# ─── Accept EULA ───
accept_eula() {
    echo "eula=${EULA}" > eula.txt
    echo "==> EULA accepted: ${EULA}"
}

# ─── Generate server.properties if not exists ───
generate_server_properties() {
    if [ ! -f "server.properties" ]; then
        echo "==> Generating server.properties..."
        cat > server.properties <<EOF
server-port=${SERVER_PORT:-25565}
difficulty=${DIFFICULTY:-normal}
gamemode=${GAMEMODE:-survival}
max-players=${MAX_PLAYERS:-20}
view-distance=${VIEW_DISTANCE:-10}
motd=${MOTD:-A Minecraft Server on Railway}
online-mode=true
enable-command-block=true
spawn-protection=0
allow-flight=true
EOF
        echo "==> server.properties created!"
    else
        # Always update the port to match Railway's assigned port
        sed -i "s/^server-port=.*/server-port=${SERVER_PORT:-25565}/" server.properties
        echo "==> server.properties exists, updated port to ${SERVER_PORT:-25565}"
    fi
}

# ─── Setup FileBrowser ───
setup_filebrowser() {
    if [ ! -f "/data/filebrowser.db" ]; then
        echo "==> Setting up FileBrowser..."
        filebrowser config init --database /data/filebrowser.db
        filebrowser config set \
            --database /data/filebrowser.db \
            --address 0.0.0.0 \
            --port "${FILEBROWSER_PORT:-8080}" \
            --root /data \
            --log /data/filebrowser.log
        # Default credentials: admin / admin (change after first login!)
        filebrowser users add admin admin --database /data/filebrowser.db --perm.admin
        echo "==> FileBrowser ready! Default login: admin / admin"
    else
        # Update port in case it changed
        filebrowser config set \
            --database /data/filebrowser.db \
            --address 0.0.0.0 \
            --port "${FILEBROWSER_PORT:-8080}"
        echo "==> FileBrowser config updated"
    fi
}

# ─── Ensure plugins directory exists ───
setup_plugins() {
    mkdir -p /data/plugins
    PLUGIN_COUNT=$(find /data/plugins -name "*.jar" 2>/dev/null | wc -l)
    echo "==> Plugins directory ready ($PLUGIN_COUNT plugin(s) found)"
}

# ─── Run everything ───
echo "============================================"
echo "  Minecraft Server on Railway"
echo "  Memory: ${MEMORY}"
echo "  MC Version: ${MC_VERSION}"
echo "============================================"

download_paper
accept_eula
generate_server_properties
setup_plugins
setup_filebrowser

echo "==> Starting services via supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
