#!/bin/bash
# Requires an archlinux install with full base group. Can be run any
# number of times and will always produce the same system.

# query for configuration
read -r -p 'Are we running as a portable machine? [y/N]' portable
graphical=y

# basics
cd / || exit
pacman="$pacman --noconfirm --needed"
$pacman -Syu grub intel-ucode

table_add() {
    local filename="$1"
    shift
    if ! sed 's/#.*//' "$filename" | cut -f 1 -d ' ' | grep -q "$1"; then
	echo "$@" >> "$filename"
    fi
}

# locale
sed -i '/en_US\.UTF-8/s/^#//' etc/locale.gen
locale-gen
if ! [ -f etc/locale.conf ]; then
    echo LANG=en_US.UTF-8 > etc/locale.conf
fi
echo KEYMAP=us > etc/vconsole.conf
echo FONT=Lat2-Terminus16 >> etc/vconsole.conf

# canada
sed -i '/en_CA\.UTF-8/s/^#//' etc/locale.gen
locale-gen
sed -i '/LANG=/s/US/CA/' etc/locale.conf
mirror_url="https://www.archlinux.org/mirrorlist/?country=CA"
curl -L "$mirror_url" | sed 's/^#//' | rankmirrors - > etc/pacman.d/mirrorlist
pacman -Syy
ln -sf usr/share/zoneinfo/Canada/Eastern etc/localtime

# systemd initramfs
sed -i '/HOOKS=/s/udev //' etc/mkinitcpio.conf
sed -i '/HOOKS=/s/base autodetect/base systemd autodetect/' etc/mkinitcpio.conf
sed -i '/HOOKS=/s/autodetect block/autodetect modconf sd-lvm2 sd-encrypt sd-vconsole block/' etc/mkinitcpio.conf

# luks and lvm, make sure to secure the keyfile (including the boot
# directory)
keyfilename="crypto_keyfile.bin" # compatibility
if ! [ -f $keyfilename ]; then
    touch $keyfilename
    chmod 600 $keyfilename
    head -c 4096 /dev/random > $keyfilename
    cryptsetup luksAddKey /dev/mapper/lvm-root $keyfilename
fi
chmod 700 boot
if [ "$graphical" = y ]; then
    sed -i "/FILES=/s/()/(\"/$keyfilename\")/" etc/mkinitcpio.conf
    sed -i '/GRUB_ENABLE_CRYPTODISK/{s/^#//;s/=n/=y}' etc/default/grub
    table_add etc/crypttab.initramfs root /dev/mapper/lvm-root /$keyfilename
else
    table_add etc/crypttab.initramfs root /dev/mapper/lvm-root
fi

# hibernate/swap space
if [ -e /dev/mapper/lvm-swap ]; then
    sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet"/quiet resume=/dev/mapper/swap"/' etc/default/grub
    cryptsetup luksOpen --keyfile $keyfilename /dev/mapper/lvm-swap swap
    mkswap /dev/mapper/swap
    table_add etc/crypttab.initramfs swap /dev/mapper/lvm-swap /$keyfilename
    table_add etc/fstab /dev/mapper/swap none swap defaults 0 0
fi

# multilib
sed -i '/\[multilib]/,+1s/^#//' etc/pacman.conf
$pacman -Sy

# completions for bash
$pacman -S bash-completion

# ssh
if [ "$portable" != y ]; then
    $pacman -S openssh
    sed -i '/#PasswordAuthentication/{s/yes/no/;s/^#//}' etc/ssh/sshd_config
    systemctl enable --now sshd
fi

# ntp
if [ "$portable" = y ]; then
    $pacman -S chrony
    systemctl enable --now chronyd
else
    timedatectl set-ntp true
fi

# kde
if [ "$graphical" = y ]; then
    $pacman -S plasma emacs chromium xterm
    systemctl enable sddm
fi

# yubikey
if [ "$graphical" = y ]; then
    $pacman -S pcsc-tools ccid libusb-compat libu2f-host
    systemctl enable --now pcscd
fi

# sudo (enable users in group wheel)
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# build user (system user without a home directory and can sudo
# without a password)
useradd --system -d /var/empty build
echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build

# aur
$pacman -S base-devel git
aur_install() {
    local package="$1"
    local dir
    dir="$(mktemp -d)"
    shift
    pushd "$dir" || return
    sudo -u build git clone https://aur.archlinux.org/"$package"
    popd || exit
    pushd "$dir/$package" || return
    sudo -u build git pull
    sudo -u build makepkg -si --noconfirm "$@"
    popd || exit
}

# aur helpers
aur_install cower
aur_install pacaur

# keep the package cache clean
cat > etc/pacman.d/hooks/clean-cache.hook <<EOF
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning pacman cache...
When = PostTransaction
Exec = /usr/bin/paccache -r
EOF

# rebuild everything
grub-mkconfig -o boot/grub/grub.cfg
if ls /sys/firmware/efi/efivars/; then
    grub-install
fi
mkinitcpio -P
hwclock --systohc
$pacman -Syyuu
$pacman -Fy
