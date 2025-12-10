# Encrypted High Availability Raspberry Pi Cluster for Dummies

## Disclaimer

> :warning: **You perform all scripts, commands and actions and use all information listed here entirely at your own risk.** :warning:

This is a work in progress. It is currently incomplete.

## Goals

- Set up a high availability [K3s](https://k3s.io/) cluster on multiple [Raspberry Pi](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) single-board computers
- Individual nodes should be fully encrypted using [LUKS](https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup)
- Nodes boot from GPT partitioned disks connected via USB 3 (SD cards used only during installation)
- Used for home automation and distributed backups

### Hardware

- [Raspberry Pi 4 Model B](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) (8 GB RAM)
- Geekworm [X832](https://wiki.geekworm.com/X832) board
- Geekworm [X735](https://wiki.geekworm.com/X735) cooling fan
- Geekworm [X832-C1](https://wiki.geekworm.com/X832-C1) case
- 12V 5A AC/DC power adapter, 5.5 x 2.5 [mm](https://en.wikipedia.org/wiki/Millimetre) round DC plug (compatible to 5.5 mm x 2.1 mm)
- 3.5" SATA harddisk

### Software

Tested with [Raspberry Pi 64-bit Lite OS 12 ("Bookworm")](https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/2024-07-04-raspios-bookworm-arm64-lite.img.xz)

## Using this Repo

```bash
git clone https://github.com/ptschack/pi-cluster.git    # clone this repo
cd pi-cluster
deactivate                                              # deactivate any running virtual environments
python3 -m venv venv                                    # create virtual environment
source venv/bin/activate                                # activate virtual environment
pip install -r requirements.txt                         # install ansible
deactivate ; source venv/bin/activate                   # reload virtual environment
ansible-galaxy install -r requirements.yml              # install Ansible Collections from your YAML file
```

## Sources

> [Raspberry Pi Encrypted Boot with SSH](https://github.com/ViRb3/pi-encrypted-boot-ssh)

## Individual node setup

### Flash Debian to SD card with customizations

- Use [Raspberry Pi Imager](https://downloads.raspberrypi.org/imager/) to set the following options and flash to an SD card
  - hostname
  - ssh key
    - disable ssh password-based login
  - username & password
  - locale

### Update Raspberry Pi firmware

Boot the Pi with the SD card you just created, it will restart multiple times. When you can log in, update the firmware, which is needed for booting from GPT partitioned disks.

```bash
sudo su
```

```bash
apt-get update
apt-get -y dist-upgrade
apt-get -y install rpi-eeprom
rpi-eeprom-update -a
reboot
```

### Partition target disk and transfer OS

Connect to the Pi, and do the following in a root shell (e.g. via `sudo su`)

```bash
TARGET_DEVICE=/dev/sdb # set TARGET_DEVICE to where you want to transfer the OS (e.g. a HDD)
apt-get update \
&& apt-get install -y cryptsetup-bin lshw \
&& SOURCE_BOOT_PARTITION=$(mount | grep ' /boot/firmware ' | awk '{print $1}') \
&& parted ${TARGET_DEVICE} mklabel gpt \
&& parted ${TARGET_DEVICE} mkpart primary fat32 1MiB 1GiB \
&& parted ${TARGET_DEVICE} mkpart primary ext4 1GiB 100% \
&& parted ${TARGET_DEVICE} set 1 boot on \
&& umount /boot/firmware \
&& mount -o ro ${SOURCE_BOOT_PARTITION} /boot/firmware \
&& cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 --pbkdf-parallel=1 ${TARGET_DEVICE}2 \
&& cryptsetup open ${TARGET_DEVICE}2 crypted \
&& mkfs.ext4 /dev/mapper/crypted \
&& mkdir -p /mnt/chroot/ \
&& mount /dev/mapper/crypted /mnt/chroot/ \
&& rsync -avHAX / /mnt/chroot/ --exclude=/boot/firmware --exclude=/mnt --exclude=/dev --exclude=/proc --exclude=/sys \
&& mkdir -p /mnt/chroot/{boot,mnt,dev,proc,sys}/ \
&& mkdir -p /mnt/chroot/boot/firmware \
&& mkfs.vfat ${TARGET_DEVICE}1 \
&& mount ${TARGET_DEVICE}1 /mnt/chroot/boot/firmware \
&& rsync -avHAX /boot/firmware /mnt/chroot/boot \
&& mount -t proc none /mnt/chroot/proc/ \
&& mount -t sysfs none /mnt/chroot/sys/ \
&& mount -o bind /dev /mnt/chroot/dev/ \
&& mount -o bind /dev/pts /mnt/chroot/dev/pts/ \
&& LANG=C chroot /mnt/chroot
```

Inside chroot, configure booting into new OS:

```bash
TARGET_DEVICE=/dev/sdb # again, set TARGET_DEVICE to where you want to transfer the OS (e.g. a HDD)
mv /etc/resolv.conf /etc/resolv.conf.bak \
&& echo "nameserver 1.1.1.1" > /etc/resolv.conf \
&& apt update \
&& apt install -y busybox cryptsetup dropbear-initramfs open-iscsi \
&& CRYPTO_PART_UUID=$(blkid | grep ${TARGET_DEVICE}2 | grep -Po '(?<= UUID=").[^"]*') \
&& echo CRYPTO_PART_UUID: ${CRYPTO_PART_UUID} \
&& NEW_BOOT_PARTUUID=$(blkid | grep ${TARGET_DEVICE}1 | grep -Po '(?<=PARTUUID=").[^"]*') \
&& echo NEW_BOOT_PARTUUID: ${NEW_BOOT_PARTUUID} \
&& sed -i 's|^[^\s]* / |/dev/mapper/crypted / |' /etc/fstab \
&& sed -i 's|^[^\s]* /boot/firmware |PARTUUID='${NEW_BOOT_PARTUUID}' /boot/firmware |' /etc/fstab \
&& echo "crypted UUID=${CRYPTO_PART_UUID} none luks,initramfs" > /etc/crypttab \
&& sed -i 's|root=.[^\s]* |root=/dev/mapper/crypted cryptdevice=UUID'=${CRYPTO_PART_UUID}':crypted |' /boot/firmware/cmdline.txt \
&& touch /boot/ssh \
&& touch /boot/firmware/ssh \
&& echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
```

```bash
patch --no-backup-if-mismatch /usr/share/initramfs-tools/hooks/cryptroot << 'EOF'
--- cryptroot
+++ cryptroot
@@ -33,7 +33,7 @@
         printf '%s\0' "$target" >>"$DESTDIR/cryptroot/targets"
         crypttab_find_entry "$target" || return 1
         crypttab_parse_options --missing-path=warn || return 1
-        crypttab_print_entry
+        printf '%s %s %s %s\n' "$_CRYPTTAB_NAME" "$_CRYPTTAB_SOURCE" "$_CRYPTTAB_KEY" "$_CRYPTTAB_OPTIONS" >&3
     fi
 }
EOF
```

```bash
sed -i 's/^TIMEOUT=.*/TIMEOUT=100/g' /usr/share/cryptsetup/initramfs/bin/cryptroot-unlock \
&& mkdir -p /root/.ssh && chmod 0700 /root/.ssh \
&& sed -i 's|^\s*BOOTDIR.*$||g' /etc/initramfs-tools/update-initramfs.conf \
&& echo 'BOOTDIR=/boot/firmware' >> /etc/initramfs-tools/update-initramfs.conf \
&& echo '# delete this line and paste your SSH keys here' > /etc/dropbear/initramfs/authorized_keys \
&& nano /etc/dropbear/initramfs/authorized_keys \
&& echo '# delete this line and paste your SSH keys here' > /root/.ssh/authorized_keys \
&& nano /root/.ssh/authorized_keys \
&& echo '# delete this line and paste your SSH keys here' > /home/$SUDO_USER/.ssh/authorized_keys \
&& nano /home/$SUDO_USER/.ssh/authorized_keys \
&& chmod 0600 /etc/dropbear/initramfs/authorized_keys /root/.ssh/authorized_keys /home/$SUDO_USER/.ssh/authorized_keys \
&& nano /etc/kernel/postinst.d/z50-update-raspi-firmware
```

Use these contents for `/etc/kernel/postinst.d/z50-update-raspi-firmware`

```bash
#!/bin/sh
# /etc/kernel/postinst.d/z50-update-raspi-firmware

# Exit if we are not receiving the version argument
if [ -z "$1" ]; then
    exit 0
fi

VERSION="$1"
BOOT_DIR="/boot/firmware"
INITRD_SRC="${BOOT_DIR}/initrd.img-${VERSION}"
INITRD_DEST="${BOOT_DIR}/initramfs.gz"

# Check if the newly generated initrd exists
if [ -f "$INITRD_SRC" ]; then
    echo "Copying ${INITRD_SRC} to ${INITRD_DEST}..."
    cp -f "$INITRD_SRC" "$INITRD_DEST"
    # Ensure it's flushed to disk
    sync
else
    echo "Warning: Expected initrd ${INITRD_SRC} not found."
fi
```

```bash
cat <<EOF | while read -r mod; do grep -Fxq "$mod" /etc/initramfs-tools/modules || echo "$mod" >> /etc/initramfs-tools/modules; done
chacha20
xchacha20
adiantum
nhpoly1305
poly1305
aes_arm64
sha256
libchacha
EOF
```

<!-- && echo "initramfs initrd.img-${KERNEL_VERSION} followkernel" >> /boot/firmware/config.txt \ -->

```bash
chmod +x /etc/kernel/postinst.d/z50-update-raspi-firmware \
&& echo 'DROPBEAR_OPTIONS="-j -k -p 2222 -s -c cryptroot-unlock"' >> /etc/dropbear/initramfs/dropbear.conf \
&& KERNELFLAVOR=$([[ $(lshw | grep -Po '(?<=product: Raspberry Pi )[^\s]*') -eq 4 ]] && echo v8 || echo 2712) \
&& KERNEL_VERSION=$(ls /lib/modules/ | grep $KERNELFLAVOR | awk '{print $1}') \
&& echo KERNEL_VERSION: $KERNEL_VERSION \
&& mkinitramfs -o /boot/firmware/initrd.img-${KERNEL_VERSION} "${KERNEL_VERSION}" \
&& cp /boot/firmware/config.txt /boot/firmware/config.txt.bak \
&& sed -i 's/^#\?auto_initramfs=.*/auto_initramfs=0/' /boot/firmware/config.txt \
&& sed -i '/^initramfs /d' /boot/firmware/config.txt \
&& sed -i '/^\[all\]/a initramfs initramfs.gz followkernel' /boot/firmware/config.txt \
&& CURRENT_KERNEL=$(uname -r) \
&& cp /boot/firmware/initrd.img-${CURRENT_KERNEL} /boot/firmware/initramfs.gz \
&& mv /etc/resolv.conf.bak /etc/resolv.conf \
&& echo -n ' cgroup_memory=1 cgroup_enable=memory' >> /boot/firmware/cmdline.txt \
&& sync \
&& history -c && exit
```

### Host cleanup

```bash
umount /mnt/chroot/boot/firmware
umount /mnt/chroot/sys
umount /mnt/chroot/proc
umount /mnt/chroot/dev/pts
umount /mnt/chroot/dev
umount /mnt/chroot
cryptsetup close crypted
shutdown -h now
```
