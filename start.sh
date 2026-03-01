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
online-mode=false
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
    FB_PASS="${FILEBROWSER_PASS:-adminadmin123}"

    # Reset DB to ensure clean credentials every deploy
    rm -f /data/filebrowser.db
    echo "==> Setting up FileBrowser..."
    filebrowser config init --database /data/filebrowser.db
    filebrowser config set \
        --database /data/filebrowser.db \
        --address 0.0.0.0 \
        --port "${FILEBROWSER_PORT:-8080}" \
        --root /data \
        --log /data/filebrowser.log \
        --auth.method=json
    # Create admin user (password must be 12+ chars)
    filebrowser users add admin "$FB_PASS" --database /data/filebrowser.db --perm.admin
    echo "==> FileBrowser ready!"
    echo "==> Login: admin / $FB_PASS"
    echo "==> (Set FILEBROWSER_PASS env var to change the password)"
}

# ─── Download essential auth plugins ───
download_plugin() {
    local name="$1"
    local url="$2"
    local dest="/data/plugins/${name}"
    if [ ! -f "$dest" ]; then
        echo "==> Downloading plugin: $name"
        wget -q -O "$dest" "$url" && echo "==> $name downloaded!" || echo "==> WARNING: Failed to download $name"
    else
        echo "==> Plugin already exists: $name"
    fi
}

setup_plugins() {
    mkdir -p /data/plugins

    # ProtocolLib (required by FastLogin)
    echo "==> Checking ProtocolLib..."
    if [ ! -f "/data/plugins/ProtocolLib.jar" ]; then
        PROTO_URL=$(curl -s "https://api.github.com/repos/dmulloy2/ProtocolLib/releases/latest" | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' | head -1)
        if [ -n "$PROTO_URL" ] && [ "$PROTO_URL" != "null" ]; then
            download_plugin "ProtocolLib.jar" "$PROTO_URL"
        else
            echo "==> WARNING: Could not find ProtocolLib download URL"
        fi
    else
        echo "==> Plugin already exists: ProtocolLib.jar"
    fi

    # AuthMe (password-based login for all players)
    echo "==> Checking AuthMe..."
    if [ ! -f "/data/plugins/AuthMe.jar" ]; then
        AUTHME_URL=$(curl -s "https://api.github.com/repos/AuthMe/AuthMeReloaded/releases/latest" | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' | head -1)
        if [ -n "$AUTHME_URL" ] && [ "$AUTHME_URL" != "null" ]; then
            download_plugin "AuthMe.jar" "$AUTHME_URL"
        else
            echo "==> WARNING: Could not find AuthMe download URL"
        fi
    else
        echo "==> Plugin already exists: AuthMe.jar"
    fi

    # FastLogin (auto-authenticates premium players, blocks name stealing)
    echo "==> Checking FastLogin..."
    if [ ! -f "/data/plugins/FastLogin.jar" ]; then

        # Primary: TuxCoding/FastLogin GitHub releases
        echo "==> Downloading FastLogin from TuxCoding/FastLogin..."
        GH_RESPONSE=$(curl -s "https://api.github.com/repos/TuxCoding/FastLogin/releases/latest")
        FASTLOGIN_URL=$(echo "$GH_RESPONSE" | jq -r '.assets[]? | select(.name | endswith(".jar")) | .browser_download_url' | head -1)
        echo "==> FastLogin URL: $FASTLOGIN_URL"
        if [ -n "$FASTLOGIN_URL" ] && [ "$FASTLOGIN_URL" != "null" ]; then
            download_plugin "FastLogin.jar" "$FASTLOGIN_URL"
        else
            # If no jar in assets, try building the download URL from tag
            TAG=$(echo "$GH_RESPONSE" | jq -r '.tag_name // empty')
            if [ -n "$TAG" ]; then
                echo "==> No jar asset found, checking all release assets..."
                echo "$GH_RESPONSE" | jq -r '.assets[]? | "\(.name) -> \(.browser_download_url)"'
                echo "==> Please manually download from https://github.com/TuxCoding/FastLogin/releases"
                echo "==> and upload FastLogin.jar to /data/plugins/ via FileBrowser"
            else
                echo "==> WARNING: Could not fetch FastLogin releases"
                echo "==> Please manually download from https://github.com/TuxCoding/FastLogin/releases"
            fi
        fi

        # Verify download
        if [ -f "/data/plugins/FastLogin.jar" ]; then
            FSIZE=$(stat -c%s "/data/plugins/FastLogin.jar" 2>/dev/null || echo 0)
            if [ "$FSIZE" -lt 1000 ]; then
                echo "==> WARNING: FastLogin.jar seems too small (${FSIZE} bytes), likely a bad download"
                rm -f "/data/plugins/FastLogin.jar"
            else
                echo "==> FastLogin.jar verified (${FSIZE} bytes)"
            fi
        fi
    else
        echo "==> Plugin already exists: FastLogin.jar"
    fi

    PLUGIN_COUNT=$(find /data/plugins -name "*.jar" 2>/dev/null | wc -l)
    echo "==> Plugins directory ready ($PLUGIN_COUNT plugin(s) found)"
}

# ─── Configure AuthMe sessions (enable auto-login on reconnect from same IP) ───
configure_authme() {
    local config="/data/plugins/AuthMe/config.yml"
    if [ -f "$config" ]; then
        echo "==> Configuring AuthMe sessions..."
        # Enable sessions
        sed -i 's/^\(\s*\)enabled: false/\1enabled: true/' "$config"
        # Set session timeout to 12 hours (720 minutes)
        sed -i 's/^\(\s*\)timeout: 10/\1timeout: 720/' "$config"
        echo "==> AuthMe sessions enabled (720 min timeout)"
    else
        echo "==> AuthMe config not found yet (will be created on first run)"
    fi
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
configure_authme
setup_filebrowser

echo "==> Starting services via supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
