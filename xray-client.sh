#!/bin/sh

# Default values
DEFAULT_PORT="10808"
CONFIG_FILE="/etc/xray/config.json"
LOG_FILE="/var/log/xray.log"

# Check if Xray is installed
check_xray_installed() {
    if [ -x "/usr/bin/xray" ]; then
        echo "Xray is installed"
        return 0
    else
        echo "Xray is not installed"
        return 1
    fi
}

# Install Xray
install_xray() {
    echo "Installing Xray..."
    wget -O /tmp/xray.ipk $(curl -s https://api.github.com/repos/yichya/openwrt-xray/releases/latest \
        | grep "browser_download_url" \
        | grep "mips_24kc.ipk" \
        | cut -d '"' -f 4)
    opkg install /tmp/xray.ipk
    rm -f /tmp/xray.ipk
    
    # Create init script
    cat << 'EOF' > /etc/init.d/xray
#!/bin/sh /etc/rc.common

START=99
STOP=10

SERVICE_USE_PID=1
SERVICE_WRITE_PID=1
SERVICE_DAEMONIZE=1

CONFIG=/etc/xray/config.json
BIN=/usr/bin/xray

start() {
    service_start $BIN -config $CONFIG
}

stop() {
    service_stop $BIN
}
EOF

    chmod +x /etc/init.d/xray
    echo "Xray installed successfully"
}

# Parse VLESS link and create config
configure_from_vless() {
    while true; do
        read -p "Enter VLESS link: " vless_link
        if [ -z "$vless_link" ]; then
            echo "Error: VLESS link cannot be empty"
            continue
        fi
        
        read -p "Enter local port (default $DEFAULT_PORT): " local_port
        local_port=${local_port:-$DEFAULT_PORT}
        
        # Validate port number
        if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
            echo "Error: Invalid port number"
            continue
        fi

        # Extract components from VLESS link
        if ! echo "$vless_link" | grep -qE '^vless://'; then
            echo "Error: Invalid VLESS link format"
            continue
        fi

        # Parse VLESS link
        local user_info=$(echo "$vless_link" | awk -F'@' '{print $1}' | cut -d'/' -f1 | cut -d':' -f2-)
        local server_info=$(echo "$vless_link" | awk -F'@' '{print $2}' | cut -d'?' -f1)
        local params=$(echo "$vless_link" | awk -F'?' '{print $2}' | cut -d'#' -f1)

        local id=$(echo "$user_info" | cut -d':' -f1)
        local server_ip=$(echo "$server_info" | cut -d':' -f1)
        local server_port=$(echo "$server_info" | cut -d':' -f2)

echo "Parsed values:"
echo "id=$id"
echo "server_ip=$server_ip"
echo "server_port=$server_port"
echo "security=$security"

        # Parse parameters
        local security=$(echo "$params" | tr '&' '\n' | grep 'security=' | cut -d'=' -f2)
        local encryption=$(echo "$params" | tr '&' '\n' | grep 'encryption=' | cut -d'=' -f2)
        local pbk=$(echo "$params" | tr '&' '\n' | grep 'pbk=' | cut -d'=' -f2)
        local host=$(echo "$params" | tr '&' '\n' | grep 'host=' | cut -d'=' -f2)
        local fp=$(echo "$params" | tr '&' '\n' | grep 'fp=' | cut -d'=' -f2)
        local type=$(echo "$params" | tr '&' '\n' | grep 'type=' | cut -d'=' -f2)
        local flow=$(echo "$params" | tr '&' '\n' | grep 'flow=' | cut -d'=' -f2)
        local sid=$(echo "$params" | tr '&' '\n' | grep 'sid=' | cut -d'=' -f2)

        # Validate required parameters
        if [ -z "$id" ] || [ -z "$server_ip" ] || [ -z "$server_port" ] || [ -z "$security" ]; then
            echo "Error: Missing required parameters in VLESS link"
            continue
        fi

        # Create config file
        cat << EOF > "$CONFIG_FILE"
{
    "log": {
        "loglevel": "debug"
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": $local_port,
            "protocol": "socks",
            "settings": {
                "udp": true
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "$server_ip",
                        "port": $server_port,
                        "users": [
                            {
                                "id": "$id",
                                "encryption": "${encryption:-none}",
                                "flow": "${flow:-xtls-rprx-vision}"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "${type:-tcp}",
                "security": "$security",
                "realitySettings": {
                    "fingerprint": "${fp:-chrome}",
                    "serverName": "$host",
                    "publicKey": "$pbk",
                    "shortId": "$sid"
                }
            },
            "tag": "proxy"
        }
    ]
}
EOF

        /etc/init.d/xray enable
        /etc/init.d/xray restart
        echo "Xray configured successfully on port $local_port"
        break
    done
}

# Start Xray
start_xray() {
    echo "$(date) - Starting Xray" >> "$LOG_FILE"
    /etc/init.d/xray start
    echo "Xray started"
}

# Stop Xray
stop_xray() {
    echo "$(date) - Stopping Xray" >> "$LOG_FILE"
    /etc/init.d/xray stop
    echo "Xray stopped"
}

# Check connection
check_connection() {
    local port=$(jq -r '.inbounds[0].port' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_PORT")
    echo "Testing connection through port $port..."
    
    if IP=$(curl -s --connect-timeout 5 --socks5 "127.0.0.1:$port" ifconfig.me); then
        echo "Current IP: $IP"
        return 0
    else
        echo "Connection failed"
        return 1
    fi
}

# Main menu
main_menu() {
    clear
    echo "========================================"
    echo "Xray Configuration for OpenWRT"
    echo "========================================"
    
    if check_xray_installed; then
        echo "1. Start Xray"
        echo "2. Stop Xray"
        echo "3. Check connection"
        echo "4. Reconfigure Xray (enter VLESS link)"
        echo "5. Exit"
        echo "========================================"

        read -p "Select option [1-5]: " choice
        case $choice in
            1) start_xray ;;
            2) stop_xray ;;
            3) check_connection ;;
            4) configure_from_vless ;;
            5) exit 0 ;;
            *) echo "Invalid option"; exit 1 ;;
        esac
    else
        echo "1. Install and configure Xray (enter VLESS link)"
        echo "2. Exit"
        echo "========================================"

        read -p "Select option [1-2]: " choice
        case $choice in
            1) 
                install_xray 
                configure_from_vless
                ;;
            2) exit 0 ;;
            *) echo "Invalid option"; exit 1 ;;
        esac
    fi
}

# Run main menu
main_menu