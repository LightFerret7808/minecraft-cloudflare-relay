#!/bin/bash

if [ -z "$BASH_VERSION" ]; then
    echo "Please run this script with bash: sudo bash install_ubuntu.sh"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash install_ubuntu.sh"
    exit 1
fi

# Install cloudflared
install_cloudflared() {
    echo "Installing cloudflared..."
    wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared.deb
    rm -f cloudflared.deb
}

# Check installation
check_installation() {
    if command -v cloudflared >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Add systemd service
add_systemd_service() {
    echo "Adding cloudflared systemd service..."
    cat <<EOF2 > /etc/systemd/system/cloudflared.service
[Unit]
Description=Minecraft Server Cloudflared Tunnel
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel run minecraft-tunnel
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared
    echo "cloudflared systemd service added and started."
}

# Delete DNS route if we can parse the old domain from config
delete_old_dns_route() {
    local old_domain
    if [ -f "/root/.cloudflared/config.yml" ]; then
        old_domain=$(grep -Eo '^\s*- hostname: mc\.[[:alnum:].-]+' /root/.cloudflared/config.yml | sed -E 's/^\s*- hostname: mc\.//')
    fi
    if [ -n "$old_domain" ]; then
        echo "Removing stale DNS route for mc.$old_domain..."
        cloudflared tunnel route dns delete minecraft-tunnel mc.$old_domain 2>/dev/null || true
    fi
}


create_config() {
    echo "Checking if a tunnel named minecraft-tunnel already exists..."

    delete_old_dns_route


    if [ -f "/root/.cloudflared/config.yml" ]; then
        rm -f "/root/.cloudflared/config.yml"
    fi

    #If the tunnel already exists
    if cloudflared tunnel list 2>/dev/null | grep -q "minecraft-tunnel"; then
        echo "Tunnel minecraft-tunnel already exists. Deleting..."
        cloudflared tunnel delete minecraft-tunnel
    fi

    if [ -f "/etc/cloudflared/minecraft-tunnel.json" ]; then
        rm -f /etc/cloudflared/minecraft-tunnel.json
    fi

    echo "Creating a tunnel using cloudflared..."
    sudo mkdir -p /etc/cloudflared

    output=$(cloudflared tunnel create minecraft-tunnel 2>&1)
    if [ $? -ne 0 ]; then
        echo "Failed to create tunnel: $output"
        exit 1
    fi

    #Extract the credentials path from the output
    credentials_path=$(echo "$output" | grep -oP 'Tunnel credentials written to \K[^[:space:]]+')
    if [ -z "$credentials_path" ]; then
        echo "Failed to parse tunnel credentials path from cloudflared output."
        exit 1
    fi

    credentials_path=$(echo "$credentials_path" | sed 's/[[:punct:]]\+$//')
    if [ ! -f "$credentials_path" ]; then
        echo "Parsed credentials path does not exist: $credentials_path"
        echo "cloudflared output was: $output"
        exit 1
    fi

    while true; do
        read -p "What's your connected domain? (e.g. example.com) " domain
        domain="$(echo "$domain" | xargs)"
        if [ -n "$domain" ]; then
            break
        fi
        echo "Domain cannot be empty. Please enter your domain."
    done

    mv "$credentials_path" /etc/cloudflared/minecraft-tunnel.json
    echo "Tunnel created and credentials moved to /etc/cloudflared/minecraft-tunnel.json"
    mkdir -p /root/.cloudflared
    cat > /root/.cloudflared/config.yml <<EOF
tunnel: minecraft-tunnel
credentials-file: /etc/cloudflared/minecraft-tunnel.json

ingress:
  - hostname: mc.${domain}
    service: tcp://localhost:25565
  - service: http_status:404
metrics: 0.0.0.0:2000
loglevel: debug
EOF
    echo "Configuration file created at /root/.cloudflared/config.yml"
    sudo cat /root/.cloudflared/config.yml

    # Automatically setup DNS record for the tunnel
    echo "Setting up DNS record for the tunnel..."
    cloudflared tunnel route dns delete minecraft-tunnel mc.${domain} 2>/dev/null || true
    if ! cloudflared tunnel route dns minecraft-tunnel mc.${domain}; then
        echo "Failed to add DNS route for mc.${domain}. Attempting to remove existing DNS record if possible..."
        if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
            record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=mc.$domain" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" | jq -r '.result[0].id')
            if [ "$record_id" != "null" ] && [ -n "$record_id" ]; then
                echo "Deleting existing DNS record mc.$domain in Cloudflare..."
                curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$record_id" \
                    -H "Authorization: Bearer $CF_API_TOKEN" \
                    -H "Content-Type: application/json"
                echo "Retrying DNS route creation..."
                cloudflared tunnel route dns minecraft-tunnel mc.${domain} || {
                    echo "Still failed to create DNS route after API delete. Please manually delete mc.$domain record in Cloudflare DNS and rerun."
                    exit 1
                }
            else
                echo "No existing CNAME record found via Cloudflare API, but route creation still failed. Please manually delete record mc.$domain in Cloudflare DNS and rerun."
                exit 1
            fi
        else
            echo "CF_API_TOKEN/CF_ZONE_ID not set. Please manually delete mc.$domain record in Cloudflare DNS and rerun."
            exit 1
        fi
    fi
}


# Show menu
show_repair_menu() {
    echo "1) Make minecraft tunnel autostart with system"
    echo "2) Recreate configuration file"
    echo "3) Re-Login to cloudflare account"
    echo "4) Exit"
    read -p "Choose an option: " choice
    case $choice in
        1)
            add_systemd_service
            ;;
        2)
            create_config
            ;;
        3)
            echo "Re-logging into cloudflare account..."
            login_cloudflare
            ;;
        4)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid option."
            show_repair_menu
            ;;
    esac
}

# Login to cloudflare account
login_cloudflare() {
    echo "Logging into cloudflare account..."
    cloudflared tunnel login
    if [ $? -ne 0 ]; then
        echo "Cloudflare login failed"
        exit 1
    fi
    cloudflared tunnel list || { echo "Login invalid"; exit 1; }
    echo "Logged in and valid"
}

# Main execution
if check_installation; then
    echo "cloudflared is already installed."
    read -p "Continue with setup? (y/n) " answer
    if [[ ! $answer =~ ^[yY]$ ]]; then
        echo "Exiting."
        exit 0
    fi
    echo "Continuing with setup..."
    show_repair_menu
else
    install_cloudflared
    if check_installation; then
        echo "cloudflared installation successful."
        create_config
        add_systemd_service
        echo "Setup complete."
    else
        echo "cloudflared installation failed."
        exit 1
    fi
fi
