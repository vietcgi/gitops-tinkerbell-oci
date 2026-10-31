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

# Build iPXE from a pinned commit (the one deployed on .67 on 2026-10-30) so
# rebuilds are reproducible. Bump IPXE_COMMIT deliberately and retest a PXE boot.
IPXE_COMMIT="b87b90415f45b9e98a9c9db088d827c442ed6ddb"

# undionly-embedded.kpxe for BIOS systems (Dell R610 Broadcom bnx2 UNDI) with an
# embedded script that retries DHCP; ipxe.efi for UEFI systems, built from the
# same source instead of downloading an unpinned binary over plain HTTP.
echo "Building iPXE $IPXE_COMMIT..."
IPXE_BUILD_DIR="/tmp/ipxe-build-$$"
git init -q "$IPXE_BUILD_DIR"
git -C "$IPXE_BUILD_DIR" fetch -q --depth 1 https://github.com/ipxe/ipxe.git "$IPXE_COMMIT"
git -C "$IPXE_BUILD_DIR" checkout -q FETCH_HEAD

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
make bin-x86_64-efi/ipxe.efi
sudo cp bin/undionly.kpxe /srv/tftp/undionly-embedded.kpxe
sudo cp bin-x86_64-efi/ipxe.efi /srv/tftp/ipxe.efi
sha256sum /srv/tftp/undionly-embedded.kpxe /srv/tftp/ipxe.efi
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
