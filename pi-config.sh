#!/bin/bash

# ==========================================
# Raspberry Pi Full-Stack Configurator
# Modifies both BOOT and ROOT partitions.
# ==========================================

# 1. Defaults & Usage
usage() {
    echo "Usage: sudo $0 -u <user> -p <pass> -s <wifi_ssid> -w <wifi_pass> -h <hostname> -k <pub_key_file> -b <boot_mount> -r <root_mount>"
    echo ""
    echo "  -u  Username"
    echo "  -p  Password"
    echo "  -s  Wi-Fi SSID"
    echo "  -w  Wi-Fi Password"
    echo "  -h  Hostname (e.g., my-pi-server)"
    echo "  -k  Path to Public SSH Key (e.g., ~/.ssh/id_rsa.pub)"
    echo "  -b  Path to BOOT partition (FAT32)"
    echo "  -r  Path to ROOT partition (ext4)"
    exit 1
}

# 2. Parse Arguments
while getopts "u:p:s:w:c:h:k:b:r:" opt; do
    case $opt in
        u) USERNAME="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        s) WIFI_SSID="$OPTARG" ;;
        w) WIFI_PASS="$OPTARG" ;;
        c) COUNTRY="$OPTARG" ;;
        h) NEW_HOSTNAME="$OPTARG" ;;
        k) SSH_KEY_FILE="$OPTARG" ;;
        b) BOOT_MNT="$OPTARG" ;;
        r) ROOT_MNT="$OPTARG" ;;
        *) usage ;;
    esac
done

# 3. Validation
if [[ -z "$COUNTRY" || -z "$USERNAME" || -z "$PASSWORD" || -z "$NEW_HOSTNAME" || -z "$BOOT_MNT" || -z "$ROOT_MNT" ]]; then
    echo "Error: Missing required arguments."
    usage
fi

if [[ ! -d "$BOOT_MNT" || ! -d "$ROOT_MNT" ]]; then
    echo "Error: Mount points do not exist."
    exit 1
fi

if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH Key file not found at $SSH_KEY_FILE"
    exit 1
fi

echo "--- Starting Configuration ---"

# ==========================================
# PART 1: BOOT PARTITION (Standard Setup)
# ==========================================
echo "[1/4] Configuring Boot Partition ($BOOT_MNT)..."

# 1.1 Enable SSH
touch "$BOOT_MNT/ssh"

# 1.2 User Config
if command -v openssl &> /dev/null; then
    ENC_PASS=$(echo "$PASSWORD" | openssl passwd -6 -stdin)
    echo "$USERNAME:$ENC_PASS" > "$BOOT_MNT/userconf.txt"
else
    echo "Error: openssl not found. Cannot encrypt password."
    exit 1
fi

# 1.3 Wi-Fi
cat << EOF > "$BOOT_MNT/wpa_supplicant.conf"
country=$COUNTRY
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASS"
    key_mgmt=WPA-PSK
}
EOF

# ==========================================
# PART 2: ROOT PARTITION (Advanced Setup)
# ==========================================
echo "[2/4] Configuring Root Partition ($ROOT_MNT)..."

# 2.1 Set Hostname (Direct File Edit)
# We update /etc/hostname and replace 'raspberrypi' in /etc/hosts
echo "$NEW_HOSTNAME" > "$ROOT_MNT/etc/hostname"
sed -i "s/raspberrypi/$NEW_HOSTNAME/g" "$ROOT_MNT/etc/hosts"
sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" "$ROOT_MNT/etc/hosts"

# ==========================================
# PART 3: SSH KEY INJECTION (Systemd Method)
# ==========================================
# We create a temporary one-shot service that runs AFTER the user is created.
if [[ -n "$SSH_KEY_FILE" ]]; then
    echo "[3/4] Injecting SSH Key Setup Service..."
    
    SSH_PUB_KEY=$(cat "$SSH_KEY_FILE")
    SCRIPT_PATH="$ROOT_MNT/usr/local/sbin/rpi-custom-ssh.sh"
    SERVICE_PATH="$ROOT_MNT/etc/systemd/system/rpi-custom-ssh.service"

    # 3.1 Create the Setup Script
    cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
# Wait for user to be created by userconf.service
while ! id "$USERNAME" >/dev/null 2>&1; do
    sleep 1
done

# Create SSH directory
USER_HOME="/home/$USERNAME"
mkdir -p "\$USER_HOME/.ssh"
echo "$SSH_PUB_KEY" >> "\$USER_HOME/.ssh/authorized_keys"

# Fix Permissions (Critical for SSH to work)
chown -R $USERNAME:$USERNAME "\$USER_HOME/.ssh"
chmod 700 "\$USER_HOME/.ssh"
chmod 600 "\$USER_HOME/.ssh/authorized_keys"

# Disable this service so it never runs again
systemctl disable rpi-custom-ssh.service
rm /usr/local/sbin/rpi-custom-ssh.sh
rm /etc/systemd/system/rpi-custom-ssh.service
EOF

    chmod +x "$SCRIPT_PATH"

    # 3.2 Create the Systemd Service Unit
    cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Inject SSH Keys on First Boot
After=userconfig.service network.target
ConditionPathExists=/usr/local/sbin/rpi-custom-ssh.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rpi-custom-ssh.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # 3.3 Enable the Service (Create Symlink manually)
    # This mimics 'systemctl enable' inside the offline image
    mkdir -p "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
    ln -sf "/etc/systemd/system/rpi-custom-ssh.service" "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/rpi-custom-ssh.service"
else
    echo "[3/4] No SSH key provided. Skipping injection."
fi

echo "---"
echo "Success! Setup complete."
echo "Username: $USERNAME | Hostname: $NEW_HOSTNAME"
echo "Unmount the partitions before removing the USB stick."