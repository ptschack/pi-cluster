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

## Using this Repo

```bash
git clone https://github.com/ptschack/pi-cluster.git    # clone this repo
cd pi-cluster
deactivate                                              # deactivate any running virtual environments
python3 -m venv venv                                    # create virtual environment
source venv/bin/activate                                # activate virtual environment
pip install -r requirements.txt                         # install ansible
deactivate ; source venv/bin/activate                   # reload virtual environment
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
apt-get update
apt-get -y dist-upgrade
apt-get -y install rpi-eeprom
rpi-eeprom-update -a
reboot
```

### Partition target disk and transfer OS

```bash
set -e
apt-get update
apt-get install -y cryptsetup-bin
TARGET_DEVICE=/dev/sda
SOURCE_BOOT_PARTITION=$(mount | grep ' /boot ' | awk '{print $1}')
parted ${TARGET_DEVICE} mklabel gpt
parted ${TARGET_DEVICE} mkpart primary fat32 1MiB 1GiB
parted ${TARGET_DEVICE} mkpart primary ext4 1GiB 100%
parted ${TARGET_DEVICE} set 1 boot on
umount /boot
mount -o ro ${SOURCE_BOOT_PARTITION} /boot
cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 --pbkdf-parallel=1 ${TARGET_DEVICE}2
cryptsetup open ${TARGET_DEVICE}2 crypted
mkfs.ext4 /dev/mapper/crypted
mkdir -p /mnt/chroot/
mount /dev/mapper/crypted /mnt/chroot/
rsync -avHAX / /mnt/chroot/ --exclude=/boot --exclude=/mnt --exclude=/dev --exclude=/proc --exclude=/sys
mkdir -p /mnt/chroot/{boot,mnt,dev,proc,sys}/
mkfs.vfat ${TARGET_DEVICE}1
mount ${TARGET_DEVICE}1 /mnt/chroot/boot
rsync -avHAX /boot /mnt/chroot
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/
```

### Chroot into new OS and configure boot

```bash
LANG=C chroot /mnt/chroot
set -e
mv /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf
apt update
apt install -y busybox cryptsetup dropbear-initramfs
TARGET_DEVICE=/dev/sda
CRYPTO_PART_UUID=$(blkid | grep ${TARGET_DEVICE}2 | grep -Po '(?<= UUID=").[^"]*')
echo CRYPTO_PART_UUID: ${CRYPTO_PART_UUID}
NEW_BOOT_PARTUUID=$(blkid | grep ${TARGET_DEVICE}1 | grep -Po '(?<=PARTUUID=").[^"]*')
echo NEW_BOOT_PARTUUID: ${NEW_BOOT_PARTUUID}
sed -i 's|^[^\s]* / |/dev/mapper/crypted / |' /etc/fstab
sed -i 's|^[^\s]* /boot |PARTUUID='${NEW_BOOT_PARTUUID}' / |' /etc/fstab
echo "crypted UUID=${CRYPTO_PART_UUID} none luks,initramfs" > /etc/crypttab
sed -i 's|root=.[^\s]* |root=/dev/mapper/crypted cryptdevice=UUID'=${CRYPTO_PART_UUID}':crypted |' /boot/cmdline.txt
touch /boot/ssh
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
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
sed -i 's/^TIMEOUT=.*/TIMEOUT=100/g' /usr/share/cryptsetup/initramfs/bin/cryptroot-unlock
mkdir -p /root/.ssh && chmod 0700 /root/.ssh
```

Add your SSH keys to the following files:

- `/etc/dropbear-initramfs/authorized_keys`
- `/root/.ssh/authorized_keys`

The set file properties accordingly:

```bash
chmod 0600 /etc/dropbear-initramfs/authorized_keys /root/.ssh/authorized_keys
sed -i 's/^#INITRD=Yes$/INITRD=Yes/g' /etc/default/raspberrypi-kernel
```

Create `/etc/initramfs-tools/hooks/update_initrd` with the following contents:

```bash
#!/bin/sh -e
# Update reference to $INITRD in $BOOTCFG, making the kernel use the new
# initrd after the next reboot.
BOOTLDR_DIR=/boot
BOOTCFG=$BOOTLDR_DIR/config.txt
INITRD_PFX=initrd.img-
INITRD=$INITRD_PFX$version

case $1 in
    prereqs) echo; exit
esac

FROM="^ *\\(initramfs\\) \\+$INITRD_PFX.\\+ \\+\\(followkernel\\) *\$"
INTO="\\1 $INITRD \\2"

T=`umask 077 && mktemp --tmpdir genramfs_XXXXXXXXXX.tmp`
trap "rm -- \"$T\"" 0

sed "s/$FROM/$INTO/" "$BOOTCFG" > "$T"

# Update file only if necessary.
if ! cmp -s "$BOOTCFG" "$T"
then
    cat "$T" > "$BOOTCFG"
fi
```

```bash
chmod +x /etc/initramfs-tools/hooks/update_initrd
KERNEL_VERSION=$(ls /lib/modules/ | awk '{print $1}')
mkinitramfs -o /boot/initrd.img-${KERNEL_VERSION} "${KERNEL_VERSION}"
echo "initramfs initrd.img-${KERNEL_VERSION} followkernel" >> /boot/config.txt
mv /etc/resolv.conf.bak /etc/resolv.conf
sync
history -c && exit
```

### Host cleanup

```bash
umount /mnt/chroot/boot
umount /mnt/chroot/sys
umount /mnt/chroot/proc
umount /mnt/chroot/dev/pts
umount /mnt/chroot/dev
umount /mnt/chroot
cryptsetup close crypted
shutdown -h now
```

## Apply Ansible roles

```bash
ansible-playbook -u 'USERNAME_ON_PI' -i hosts site.yml --ask-become-pass
```

## Install K3s

Source: [Production like Kubernetes on Raspberry Pi: Load-balancer](https://michael-tissen.medium.com/production-like-kubernetes-on-raspberry-pi-load-balancer-ae3ba8883a52)

Prepare node and install K3s:

```bash
# append cgroup_memory=1 cgroup_enable=memory to /boot/cmdline.txt and reboot
curl -sfL https://get.k3s.io | sh -
sudo kubectl get nodes
```

Copy `/etc/rancher/k3s/k3s.yaml` to control machine as `~/.kube/config` and check status:

```bash
kubectl run hello-raspi --image=busybox -- /bin/sh -c 'while true; do echo $(date)": Hello Raspi"; sleep 2; done'
kubectl get pods
kubectl delete pod hello-raspi
```

### Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/metallb.yaml
kubectl apply -f metallb/address-pool.yaml
```

### Install Traefik

```bash
helm repo add traefik https://traefik.github.io/charts
helm upgrade --install --values=traefik/values.yml --namespace kube-system traefik traefik/traefik
kubectl -n kube-system get pods
kubectl -n kube-system get service
kubectl apply -f traefik/dashboard-ingress-rule.yml
```

### Let's Encrypt

> still to do
<!-- ```bash
kubectl apply -f letsencrypt/ingress_class.yml
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace  --version v1.11.0  --set installCRDs=true
``` -->

### Install Longhorn

```bash
# on node
sudo apt-get install open-iscsi
sudo nano /etc/sysctl.d/k3s.conf
# net.bridge.bridge-nf-call-ip6tables = 1
# net.bridge.bridge-nf-call-iptables = 1
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
kubectl apply -f longhorn/route.yml
```
