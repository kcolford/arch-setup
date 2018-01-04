#!/bin/bash
# Requires an archlinux install with full base group and an active
# internet connection. Assumed to be installed on an lvm system. Can
# be run any number of times and will always produce the same system.

# We use an unconventional way of declaring variables so disable some
# checks.
#
# shellcheck disable=SC2154

read_def() {
    local msg="$1" var="$2" default
    if default="$(expr "$var" : '.*=\(.*\)')"; then
	var="$(expr "$var" : '\(.*\)=.*')"
    else
	default="${!var}"
    fi
    read -erp "$msg (default: $default): " "$var"
    "$var"="${!var:-$default}"
}

read_def 'Are we running as a portable machine? ' portable=n
read_def 'Are we a graphical installation?' graphical=y
read_def 'LVM volume group' vg="$(vgs | awk '{print $1}' | sed '2p;d')"
read_def 'Country code' country=CA
read_def 'Locale' locale=en_CA
read_def 'Timezone' timezone=America/Toronto
read_def 'Key file name' keyfilename=/crypto_keyfile.bin

cut_out() {
    awk "{print \$${1:-1}}"
}

table_add_idx() {
    local idx="$1" filename="$2"
    shift 2
    if ! sed 's/#.*//' "$filename" | cut_out "$idx" | fgrep -xq "$1"; then
	echo "$@" >> "$filename"
    fi
}

table_add() {
    table_add 1 "$@"

# locale
sed -i '1,24{p;d};/en_US\.UTF-8/s/^#//' /etc/locale.gen
sed -i "1,24{p;d};/$locale\\.UTF-8/s/^#//" /etc/locale.gen
locale-gen
if ! [ -f /etc/locale.conf ]; then
    echo LANG="$locale".UTF-8 > /etc/locale.conf
fi
if ! [ -f /etc/vconsole.conf ]; then
    echo KEYMAP=us > /etc/vconsole.conf
    echo FONT=Lat2-Terminus16 >> /etc/vconsole.conf
fi

# pacman mirror
mirror_url="https://www.archlinux.org/mirrorlist/?country=$country"
curl "$mirror_url" | sed 's/^#//' | rankmirrors - > /etc/pacman.d/mirrorlist

# timezone
ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime
table_add /etc/environment TZ="$timezone"

# update the system
pacman="${PACMAN:-pacman} --noconfirm --needed"
$pacman -Syu

# systemd initramfs
sed -i '/HOOKS=/s/udev //' /etc/mkinitcpio.conf
sed -i '/HOOKS=/s/base autodetect/base systemd autodetect/' /etc/mkinitcpio.conf
sed -i '/HOOKS=/s/modconf block/modconf sd-lvm2 sd-encrypt sd-vconsole block/' /etc/mkinitcpio.conf

# use grub with intel microcode
$pacman -S grub
case "$(uname -m)" in
    i386|x86_64)
	$pacman -S intel-ucode
	;;
esac

# multilib
sed -i '/\[multilib]/,+1s/^#//' /etc/pacman.conf
$pacman -Sy

# completions for bash
$pacman -S bash-completion

# ssh
if [ "$portable" != y ]; then
    $pacman -S openssh
    sed -i '/#PasswordAuthentication/{s/yes/no/;s/^#//}' /etc/ssh/sshd_config
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

# personal configuration
if [ "$graphical" = y ]; then
    $pacman -S stow git
fi

# sudo (enable users in group wheel)
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

# build user (no login user that can sudo without a password,
# basically root)
useradd --system -m build
echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build
sudo -u build mkdir -pm600 ~build/.gnupg/
sudo -u build touch ~build/.gnupg/gpg.conf
table_add ~build/.gnupg/gpg.conf auto-key-retrieve

# aur
$pacman -S base-devel git
aur_install() {
    local package="$1"
    local dir
    dir="$(sudo -u build mktemp -d)"
    shift
    pushd "$dir" || return
    sudo -u build git clone https://aur.archlinux.org/"$package" > /dev/null
    popd || exit
    pushd "$dir/$package" || return
    sudo -u build makepkg -si --noconfirm "$@"
    popd || exit
    rm -rf "$dir"
}

# aur helpers
aur_install cower
aur_install pacaur

# luks and lvm, make sure to secure the keyfile (including the boot
# directory)
if ! [ -e "$keyfilename" ]; then
    touch "$keyfilename"
    chmod 600 "$keyfilename"
    head -c 4096 /dev/random > "$keyfilename"
else
    chmod 600 "$keyfilename"
fi
chmod 700 boot
if cryptsetup isLuks /dev/mapper/"$vg"-root; then
    cryptsetup luksAddKey /dev/mapper/"$vg"-root "$keyfilename"
    if [ "$graphical" = y ]; then
	sed -i "/FILES=/s/()/(\"$keyfilename\")/" /etc/mkinitcpio.conf
	sed -i '/GRUB_ENABLE_CRYPTODISK/{s/^#//;s/=n/=y}' /etc/default/grub
	table_add /etc/crypttab.initramfs root /dev/mapper/"$vg"-root "$keyfilename"
    else
	table_add /etc/crypttab.initramfs root /dev/mapper/"$vg"-root
    fi

    aur_install pam-cryptsetup-git
    table_add_idx 3 auth [default=ignore] pam_cryptsetup.so crypt-name=root
fi

# hibernate/swap space
if [ -e /dev/mapper/lvm-swap ]; then
    sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet"/quiet resume=/dev/mapper/swap"/' /etc/default/grub
    cryptsetup luksOpen --keyfile "$keyfilename" /dev/mapper/lvm-swap swap
    mkswap /dev/mapper/swap
    table_add /etc/crypttab.initramfs swap /dev/mapper/lvm-swap "$keyfilename"
    table_add /etc/fstab /dev/mapper/swap none swap defaults 0 0
fi

# keep the package cache clean
mkdir etc/pacman.d/hooks
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
if ls /sys/firmware/efi/efivars/ > /dev/null; then
    grub-install
fi
mkinitcpio -P
hwclock --systohc
$pacman -Syu
pacman -Fy
chmod 440 /etc/sudoers.d/*
visudo -c || exit
