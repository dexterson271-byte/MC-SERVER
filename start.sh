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

    # Remove FastLogin and ProtocolLib if present (caused conflicts)
    rm -f /data/plugins/FastLogin.jar /data/plugins/ProtocolLib.jar
    rm -rf /data/plugins/FastLogin /data/plugins/ProtocolLib

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

    PLUGIN_COUNT=$(find /data/plugins -name "*.jar" 2>/dev/null | wc -l)
    echo "==> Plugins directory ready ($PLUGIN_COUNT plugin(s) found)"
}

# ─── Configure AuthMe (sessions + relaxed password policy) ───
configure_authme() {
    mkdir -p /data/plugins/AuthMe

    local config="/data/plugins/AuthMe/config.yml"

    if [ -f "$config" ]; then
        # Config exists from previous run - patch it BEFORE server starts
        # so AuthMe loads with sessions already enabled
        echo "==> Patching AuthMe config before server starts..."

        # Enable sessions
        sed -i '/sessions:/{ n; s/enabled: false/enabled: true/ }' "$config"
        # Set session timeout to ~2 years
        sed -i 's/timeout: 10$/timeout: 1051200/' "$config"
        # Also handle if timeout was already patched previously
        sed -i '/sessions:/,/timeout:/ { s/timeout: [0-9]*/timeout: 1051200/ }' "$config"
        # Relax minimum password length to 4
        sed -i 's/minPasswordLength: [0-9]*/minPasswordLength: 4/' "$config"
        # Unlimited registrations per IP
        sed -i 's/maxRegPerIp: [0-9]*/maxRegPerIp: 0/' "$config"

        echo "==> AuthMe config patched! Sessions ON, timeout ~2 years, min pass 4 chars"
    else
        # First run ever - no config exists yet
        # AuthMe will generate a default config on startup
        # We use a background patcher to modify it, then restart MC process
        echo "==> First run: AuthMe config doesn't exist yet"
        echo "==> Background patcher will configure it and restart MC automatically"

        cat > /data/plugins/AuthMe/patch-config.sh <<'PATCH'
#!/bin/bash
CONFIG="/data/plugins/AuthMe/config.yml"
echo "[AuthMe Patcher] Waiting for AuthMe to generate config..."
for i in $(seq 1 120); do
    if [ -f "$CONFIG" ]; then
        echo "[AuthMe Patcher] Config found! Waiting for write to finish..."
        sleep 5

        # Enable sessions
        sed -i '/sessions:/{ n; s/enabled: false/enabled: true/ }' "$CONFIG"
        # Set session timeout to ~2 years
        sed -i 's/timeout: 10$/timeout: 1051200/' "$CONFIG"
        sed -i '/sessions:/,/timeout:/ { s/timeout: [0-9]*/timeout: 1051200/ }' "$CONFIG"
        # Relax minimum password length
        sed -i 's/minPasswordLength: [0-9]*/minPasswordLength: 4/' "$CONFIG"
        # Unlimited registrations per IP
        sed -i 's/maxRegPerIp: [0-9]*/maxRegPerIp: 0/' "$CONFIG"

        echo "[AuthMe Patcher] Config patched! Restarting MC to apply..."

        # Restart the minecraft process so AuthMe reloads with patched config
        sleep 3
        supervisorctl restart minecraft
        echo "[AuthMe Patcher] MC restarted. Sessions are now active!"
        exit 0
    fi
    sleep 2
done
echo "[AuthMe Patcher] WARNING: Config was not generated within 4 minutes"
PATCH
        chmod +x /data/plugins/AuthMe/patch-config.sh
        nohup /data/plugins/AuthMe/patch-config.sh &>/data/authme-patcher.log &
        echo "==> Background patcher started"
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
