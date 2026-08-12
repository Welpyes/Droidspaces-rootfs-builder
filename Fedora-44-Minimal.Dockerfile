# Dockerfile (Fedora 44 Minimal)
# Stage 1: Build and customize the rootfs for development (Minimal - Fedora 44)
ARG TARGETPLATFORM
FROM fedora:44 AS customizer

# Speed up downloads
RUN echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf && \
    echo "fastestmirror=True" >> /etc/dnf/dnf.conf && \
    echo "defaultyes=True" >> /etc/dnf/dnf.conf

# Install minimal package set
RUN dnf install -y --setopt=install_weak_deps=False \
    # Core utilities
    bash \
    jq \
    dialog \
    coreutils \
    file \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    ca-certificates \
    bash-completion \
    systemd-udev \
    dbus-daemon \
    systemd \
    systemd-pam \
    systemd-resolved \
    # Basic tools
    git \
    nano \
    sudo \
    # Networking & SSH
    openssh-server \
    net-tools \
    iptables \
    iputils \
    iproute \
    bind-utils \
    # System monitoring
    procps-ng \
    # Kernel module support & locale
    kmod \
    tzdata \
    glibc-locale-source \
    glibc-langpack-en && \
    dnf upgrade -y && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Copy our bashrc script to the rootfs
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

# Make scripts executable
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Configure legacy iptables (MANDATORY for Android compatibility)
RUN ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
    ln -sf /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -sf /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore && \
    ln -sf /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-save && \
    ln -sf /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore

# Configure locales, environment, SSH, and user setup
RUN echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
    echo "LC_ALL=en_US.UTF-8" >> /etc/locale.conf && \
    # Configure SSH (Disable Root Login)
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # Create default user
    useradd -m -s /bin/bash Gold && echo "Gold:1234" | chpasswd

# Fix DHCP in the container
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# Apply Android compatibility fixes (Systemd and Udev)
RUN <<EOF_RUN

# --- 1. General Fixes ---
# Android network group setup (required for socket access on Android kernels)
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,wheel Gold || true

# Ensure future users created with useradd also get network groups
if [ -f /etc/default/useradd ]; then
    sed -i '/^GROUPS=/d' /etc/default/useradd
    echo 'GROUPS="aid_inet,aid_net_raw,input,video,tty"' >> /etc/default/useradd
fi

# --- 2. Systemd-Specific Fixes ---
# Mask problematic services for Android kernels
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

# Journald configuration (skip Audit, KMsg, etc)
cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

# Enable essential services
mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"
for service in dbus.service systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
        ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done

# Disable power button handling in systemd-logind
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# Apply udev overrides
# 1. Trigger override (Prevents coldplugging Android hardware)
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 2. Read-only path overrides to prevent failures
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# Limit specific network services to only start in NAT mode
# Prevents cellular network breakage when running in host network mode
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
EOF
    fi
done

# Configure logrotate for Android
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# Final cleanup
RUN dnf clean all && \
    rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
