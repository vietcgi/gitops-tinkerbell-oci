#!/bin/bash
set -e

# Colocation Bootstrapper Setup Script
# This script installs necessary packages and deploys configuration files.

echo "Starting Colocation Bootstrapper Setup..."

# 1. Install Dependencies
echo "Installing ISC-DHCP, TFTP, Nginx, and build tools..."
sudo apt-get update
sudo apt-get install -y isc-dhcp-server tftpd-hpa nginx wget git build-essential liblzma-dev

# 2. Deploy ISC-DHCP Config
echo "Configuring ISC-DHCP..."
sudo cp dhcpd.conf /etc/dhcp/dhcpd.conf
# Ensure the interface is set (User might need to adjust INTERFACESv4 in /etc/default/isc-dhcp-server)
echo "NOTE: Please ensure INTERFACESv4 is set correctly in /etc/default/isc-dhcp-server"
sudo systemctl restart isc-dhcp-server

# 3. Deploy TFTP Config
echo "Configuring TFTP..."
sudo mkdir -p /srv/tftp
sudo cp tftpd-hpa /etc/default/tftpd-hpa
sudo systemctl restart tftpd-hpa

# 4. Download/Build iPXE Binaries
echo "Setting up iPXE binaries..."
sudo mkdir -p /srv/tftp

# Download ipxe.efi for UEFI systems
if [ ! -f /srv/tftp/ipxe.efi ]; then
    echo "Downloading ipxe.efi..."
    sudo wget -O /srv/tftp/ipxe.efi http://boot.ipxe.org/ipxe.efi
fi

# Build undionly-embedded.kpxe with static IP fallback for BIOS systems
# This is needed for Dell R610 (Broadcom bnx2) which has buggy UNDI driver
echo "Building undionly-embedded.kpxe with static IP fallback..."
IPXE_BUILD_DIR="/tmp/ipxe-build-$$"
git clone --depth 1 https://github.com/ipxe/ipxe.git "$IPXE_BUILD_DIR"

# Create embedded script that retries DHCP. No static fallback: a shared
# fallback IP (it was .87) collides with whichever host owns it (anvil), so
# replies go to the wrong MAC and the chain times out.
cat > "$IPXE_BUILD_DIR/embed.ipxe" << 'IPXESCRIPT'
#!ipxe
set attempt:int32 0
:retry_dhcp
dhcp && goto chain || inc attempt
iseq ${attempt} 5 && goto failed || echo DHCP failed, retry ${attempt}/5 in 5s
sleep 5
goto retry_dhcp

:chain
echo Chainloading to Tinkerbell...
chain http://108.181.38.67:8080/handoff.ipxe || goto failed

:failed
echo Network boot failed, returning to BIOS boot order
exit
IPXESCRIPT

cd "$IPXE_BUILD_DIR/src"
make bin/undionly.kpxe EMBED="$IPXE_BUILD_DIR/embed.ipxe"
sudo cp bin/undionly.kpxe /srv/tftp/undionly-embedded.kpxe
cd -
rm -rf "$IPXE_BUILD_DIR"

echo "iPXE binaries ready:"
ls -la /srv/tftp/*.efi /srv/tftp/*.kpxe 2>/dev/null || true

# 5. Deploy Nginx Config and Handoff Script
echo "Configuring Nginx..."
sudo cp nginx.conf /etc/nginx/sites-available/bootstrapper
sudo ln -sf /etc/nginx/sites-available/bootstrapper /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx

echo "Deploying Handoff Script..."
sudo mkdir -p /var/www/html
sudo cp handoff.ipxe /var/www/html/handoff.ipxe

echo "Setup Complete!"
echo "Please verify services are running:"
echo "  systemctl status isc-dhcp-server"
echo "  systemctl status tftpd-hpa"
echo "  systemctl status nginx"
