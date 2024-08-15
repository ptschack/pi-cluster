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
TARGET_DEVICE=/dev/sda # set TARGET_DEVICE to where you want to transfer the OS (e.g. a HDD)
```

```bash
echo $TARGET_DEVICE
apt-get update
apt-get install -y cryptsetup-bin lshw
SOURCE_BOOT_PARTITION=$(mount | grep ' /boot/firmware ' | awk '{print $1}')
echo SOURCE_BOOT_PARTITION: $SOURCE_BOOT_PARTITION
parted ${TARGET_DEVICE} mklabel gpt
parted ${TARGET_DEVICE} mkpart primary fat32 1MiB 1GiB
parted ${TARGET_DEVICE} mkpart primary ext4 1GiB 100%
parted ${TARGET_DEVICE} set 1 boot on
umount /boot/firmware
mount -o ro ${SOURCE_BOOT_PARTITION} /boot/firmware
cryptsetup luksFormat -c xchacha20,aes-adiantum-plain64 --pbkdf-memory 512000 --pbkdf-parallel=1 ${TARGET_DEVICE}2
cryptsetup open ${TARGET_DEVICE}2 crypted
mkfs.ext4 /dev/mapper/crypted
mkdir -p /mnt/chroot/
mount /dev/mapper/crypted /mnt/chroot/
rsync -avHAX / /mnt/chroot/ --exclude=/boot/firmware --exclude=/mnt --exclude=/dev --exclude=/proc --exclude=/sys
mkdir -p /mnt/chroot/{boot,mnt,dev,proc,sys}/
mkdir -p /mnt/chroot/boot/firmware
mkfs.vfat ${TARGET_DEVICE}1
mount ${TARGET_DEVICE}1 /mnt/chroot/boot/firmware
rsync -avHAX /boot/firmware /mnt/chroot/boot
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/
LANG=C chroot /mnt/chroot
```

Inside chroot, configure booting into new OS:

```bash
TARGET_DEVICE=/dev/sda # again, set TARGET_DEVICE to where you want to transfer the OS (e.g. a HDD)
```

```bash
mv /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf
apt update
apt install -y busybox cryptsetup dropbear-initramfs open-isci
CRYPTO_PART_UUID=$(blkid | grep ${TARGET_DEVICE}2 | grep -Po '(?<= UUID=").[^"]*')
echo CRYPTO_PART_UUID: ${CRYPTO_PART_UUID}
NEW_BOOT_PARTUUID=$(blkid | grep ${TARGET_DEVICE}1 | grep -Po '(?<=PARTUUID=").[^"]*')
echo NEW_BOOT_PARTUUID: ${NEW_BOOT_PARTUUID}
sed -i 's|^[^\s]* / |/dev/mapper/crypted / |' /etc/fstab
sed -i 's|^[^\s]* /boot/firmware |PARTUUID='${NEW_BOOT_PARTUUID}' /boot/firmware |' /etc/fstab
echo "crypted UUID=${CRYPTO_PART_UUID} none luks,initramfs" > /etc/crypttab
sed -i 's|root=.[^\s]* |root=/dev/mapper/crypted cryptdevice=UUID'=${CRYPTO_PART_UUID}':crypted |' /boot/firmware/cmdline.txt
touch /boot/ssh
touch /boot/firmware/ssh
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
sed -i 's|^\s*BOOTDIR.*$||g' /etc/initramfs-tools/update-initramfs.conf
echo 'BOOTDIR=/boot/firmware' >> /etc/initramfs-tools/update-initramfs.conf
```

Paste your SSH keys to the following files and set file properties accordingly:

```bash
nano /etc/dropbear/initramfs/authorized_keys
nano /root/.ssh/authorized_keys
nano /home/$SUDO_USER/.ssh/authorized_keys
chmod 0600 /etc/dropbear/initramfs/authorized_keys /root/.ssh/authorized_keys
```

Create `/etc/initramfs-tools/hooks/update_initrd` with the following contents:

```bash
#!/bin/sh -e
# Update reference to $INITRD in $BOOTCFG, making the kernel use the new
# initrd after the next reboot.
BOOTLDR_DIR=/boot/firmware
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
echo 'DROPBEAR_OPTIONS="-j -k -p 2222 -s -c cryptroot-unlock"' >> /etc/dropbear/initramfs/dropbear.conf
KERNELFLAVOR=$([[ $(lshw | grep -Po '(?<=product: Raspberry Pi )[^\s]*') -eq 4 ]] && echo v8 || echo 2712)
KERNEL_VERSION=$(ls /lib/modules/ | grep $KERNELFLAVOR | awk '{print $1}')
echo KERNEL_VERSION: $KERNEL_VERSION
mkinitramfs -o /boot/firmware/initrd.img-${KERNEL_VERSION} "${KERNEL_VERSION}"
echo "initramfs initrd.img-${KERNEL_VERSION} followkernel" >> /boot/firmware/config.txt
mv /etc/resolv.conf.bak /etc/resolv.conf
echo -n ' cgroup_memory=1 cgroup_enable=memory' >> /boot/firmware/cmdline.txt
sync
history -c && exit
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

### Boot and connect

- Remove the SD card from the Pi
- When you boot it up, check which IP it has and connect via `ssh -p 2222 root@<IP OF PI>`
- It should prompt you for the HDD password
- After successfully entering the password, you are disconnected from the session as the Pi boots
- connect via `ssh pi@<HOSTNAME>`

### Grow swap space

```bash
SWAPFILE=/var/swap
while read i; do
  if [ ! -z "$i" ]; then
    echo "deactivate & remove $i"
    swapoff $i
    rm -f $i
  fi
done<<<$(swapon --show | grep -v 'NAME' | awk '{print $1}')
if [ -e $SWAPFILE ]; then
  rm -f $SWAPFILE
fi
dd if=/dev/zero of=$SWAPFILE bs=1M count=16384 oflag=append conv=notrunc
chmod 0600 $SWAPFILE
mkswap $SWAPFILE
swapon $SWAPFILE
swapon --show
```

## Apply Ansible roles

```bash
ansible-playbook -u 'USERNAME_ON_PI' -i hosts site.yml --ask-become-pass
```

## Install K3s

Source: [Production like Kubernetes on Raspberry Pi: Load-balancer](https://michael-tissen.medium.com/production-like-kubernetes-on-raspberry-pi-load-balancer-ae3ba8883a52)

Prepare node and install K3s:

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=SECRET sh -s - server --cluster-init
sudo kubectl get nodes
```

Copy `/etc/rancher/k3s/k3s.yaml` to control machine as `~/.kube/config` and check status:

```bash
kubectl get namespaces
```

## Install Longhorn

Source: [K3s Docs](https://docs.k3s.io/storage#setting-up-longhorn)

```bash
# on node
sudo apt-get install open-iscsi
sudo echo 'net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
'> /etc/sysctl.d/k3s.conf
```

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.2/deploy/longhorn.yaml
kubectl -n longhorn-system edit cm longhorn-storageclass # change numberOfReplicas: to "1" for single-node cluster
```

## Install MetalLB

Choose an IP range which is not in use in your network, and configure it in `metallb/address-pool.yml`. Install MetalLB and apply the address pool.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl apply -f metallb/address-pool.yml
```

## Install Istio

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
kubectl create namespace istio-system
helm install istio-base istio/base -n istio-system --set defaultRevision=default --set cni.enabled=true
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
helm install istio-cni istio/cni -n kube-system
helm install istiod istio/istiod -n istio-system --set pilot.cni.enabled=true --wait
```

## Install Dashboard

Source: [K3s Docs](https://docs.k3s.io/installation/kube-dashboard)
Find the newest version [here](https://github.com/kubernetes/dashboard/releases).

```bash
# Add kubernetes-dashboard repository
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
# Deploy a Helm Release named "kubernetes-dashboard" using the kubernetes-dashboard chart
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard
kubectl apply -f kubernetes-dashboard/dashboard.admin-user.yml
# kubectl -n kubernetes-dashboard create sa admin-user
kubectl -n kubernetes-dashboard create token admin-user > ~/.kube/admin-user.token
cat ~/.kube/admin-user.token
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443
```

The Dashboard is now accessible at [https://localhost:8443](https://localhost:8443). Sign In with the admin-user Bearer Token (in `~/.kube/admin-user.token`).

## Add another node to the cluster

<!-- On control machine, get the node token:

```bash
cat /var/lib/rancher/k3s/server/node-token
``` -->

To add a node, run command on that node:

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=SECRET K3S_URL=https://<existing-master-ip>:6443 sh -s - server --cluster-init
```

