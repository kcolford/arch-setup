#!/bin/bash
# Requires an archlinux install with full base group and an active
# internet connection. Assumed to be installed on an lvm system. Can
# be run any number of times and will always produce the same system.

set -e

# lock the root account
passwd -l root

# locale
sed -i '1,24{p;d};/en_US\.UTF-8/s/^#//' /etc/locale.gen
sed -i '1,24{p;d};/en_CA\.UTF-8/s/^#//' /etc/locale.gen
locale-gen
if ! [ -f /etc/locale.conf ]; then
    cat > /etc/locale.conf <<eof
LANG=en_CA.UTF-8
eof
fi
if ! [ -f /etc/vconsole.conf ]; then
    cat > /etc/vconsole.conf <<eof
KEYMAP=us
FONT=Lat2-Terminus16
eof
fi

# timezone
ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime
systemctl enable systemd-timesyncd
hwclock --systohc

# pacman mirror
mirror_url="https://www.archlinux.org/mirrorlist/?country=CA"
curl "$mirror_url" | sed 's/^#//' | rankmirrors - > /etc/pacman.d/mirrorlist

# update the system
pacman_flags="--noconfirm --needed"
pacman="${PACMAN:-pacman} $pacman_flags"
$pacman -Syu base base-devel

# multilib
sed -i '/\[multilib]/,+1s/^#//' /etc/pacman.conf
$pacman -Sy
pacman -Fy

# use grub with intel microcode
$pacman -S grub
case "$(uname -m)" in
    i386|x86_64)
	$pacman -S intel-ucode
	;;
esac
grub-mkconfig -o /boot/grub/grub.cfg
if [ -d /sys/firmware/efi/efivars/ ]; then
    grub-install
fi

# completions for bash
$pacman -S bash-completion

# ssh
$pacman -S openssh
sed -i '/#PasswordAuthentication/{s/yes/no/;s/^#//}' /etc/ssh/sshd_config
systemctl enable --now sshd

# kde
$pacman -S plasma emacs chromium xterm
systemctl enable sddm

# yubikey
$pacman -S pcsc-tools ccid libusb-compat libu2f-host
systemctl enable --now pcscd

# personal configuration
$pacman -S stow git

# certbot
$pacman -S certbot
cat > /etc/systemd/system/certbot.service <<eof
[Unit]
Description=Lets Encrypt renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --agree-tos
eof
cat > /etc/systemd/system/certbot.timer <<eof
[Unit]
Description=Twice daily renewal of Let's Encrypt's certificates

[Timer]
OnCalendar=0/12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
eof
systemctl enable --now certbot.timer

# database
$pacman -S postgresql
sudo -u postgres initdb --auth-host pam --auth-local peer /var/lib/postgres/data || true
setfacl -m g:postgres:r /etc/shadow
cat > /var/lib/postgres/data/postgresql.conf <<eof
listen_addresses = '*'
#ssl = on
ssl_cert_file = '/etc/letsencrypt/live/$(hostname -f)/fullchain.pem'
ssl_key_file = '/etc/letsencrypt/live/$(hostname -f)/privkey.pem'
eof
sudo systemctl enable --now postgresql

# sudo (enable users in group wheel)
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
visudo -c

# build user (no login user that can sudo without a password,
# basically root)
useradd --system -m build || true
echo "build ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/build
chmod 440 /etc/sudoers.d/build
visudo -c
mkdir -p ~build/.gnupg/
echo auto-key-retrieve > ~build/.gnupg/gpg.conf
chown -R build:build ~build/.gnupg/
chmod 700 ~build/.gnupg/

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/cleanup.hook <<eof
[Trigger]
Operation = Remove
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Clean the package cache.
When = PostTransaction
Exec = /usr/bin/paccache -r
eof

# aur
$pacman -S git
aur_install() {
    local package="$1"
    local dir
    dir="$(sudo -u build mktemp -d)"
    shift
    pushd "$dir" || return
    sudo -u build git clone https://aur.archlinux.org/"$package" > /dev/null
    popd || exit
    pushd "$dir/$package" || return
    sudo -u build makepkg -si $pacman_flags "$@"
    popd || exit
    rm -rf "$dir"
}

# aur helpers
aur_install cower
aur_install pacaur

