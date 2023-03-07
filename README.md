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

## Individual node setup

### Flash Debian to SD card

- Download [Raspberry Pi OS Lite](https://downloads.raspberrypi.org/raspios_lite_arm64/images/) 64 Bit
- Use [Raspberry Pi Imager](https://downloads.raspberrypi.org/imager/) to set the following options and flash to an SD card
  - hostname
  - ssh key
    - disable ssh password-based login
  - username & password
  - locale

### Update Raspberry Pi firmware

Enables booting from USB/GPT.

```bash
sudo apt-get update
sudo apt-get dist-upgrade
sudo apt-get install rpi-eeprom
sudo rpi-eeprom-update -a
```

### Variant 1: Partial encryption (system not encrypted, only data partition)

> Source: [HOWTO: Booting the Pi from a GPT partitioned USB Disk](https://forums.raspberrypi.com/viewtopic.php?p=1912293#p1912293)

```bash
sudo su
TARGET_DEVICE=/enter/target/device/here     # WARNING: ALL DATA ON ALL PARTITIONS OF THIS DEVICE WILL BE ERASED
THIS_DEVICE=/dev/mmcblk0p1                  # this is typically the device path of the sd card
NUM_SECTORS=$(fdisk -l $THIS_DEVICE | grep -Poe '[0-9]+ sectors' | grep -Po '[0-9]+')
wipefs -a $TARGET_DEVICE
fdisk $TARGET_DEVICE
# Command (m for help): g
# Created a new GPT disklabel (GUID: xxx).
# Command (m for help): n
# Partition number (1-128, default 1): 1
# First sector (2048-35156656094, default 2048): 2048
# Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-35156656094, default 35156656094): +256M

# Created a new partition 1 of type 'Linux filesystem' and of size 256 MiB.
# Command (m for help): t
# Selected partition 1
# Partition type or alias (type L to list all): 11
# Changed type of partition 'Linux filesystem' to 'Microsoft basic data'.

# Command (m for help): n
# Partition number (2-128, default 2): 2
# First sector (526336-35156656094, default 526336): 
# Last sector, +/-sectors or +/-size{K,M,G,T,P} (526336-35156656094, default 35156656094): +64G
# Created a new partition 2 of type 'Linux filesystem' and of size 64 GiB.

# Command (m for help): n
# Partition number (3-128, default 3): 3
# First sector (134744064-35156656094, default 134744064): 
# Last sector, +/-sectors or +/-size{K,M,G,T,P} (134744064-35156656094, default 35156656094): +32G
# Created a new partition 3 of type 'Linux filesystem' and of size 32 GiB.

# Command (m for help): t
# Partition number (1-3, default 3): 3
# Partition type or alias (type L to list all): 19
# Changed type of partition 'Linux filesystem' to 'Linux swap'.

# Command (m for help): n
# Partition number (4-128, default 4): 4
# First sector (201852928-35156656094, default 201852928): 
# Last sector, +/-sectors or +/-size{K,M,G,T,P} (201852928-35156656094, default 35156656094): 
# Created a new partition 4 of type 'Linux filesystem' and of size 16.3 TiB.

# Command (m for help): w
# The partition table has been altered.
# Calling ioctl() to re-read partition table.
# Syncing disks.

umount /boot
dd if=${THIS_DEVICE} of=${TARGET_DEVICE}1
mkfs.ext4 ${TARGET_DEVICE}2
mkdir -p /mnt/new
mount ${TARGET_DEVICE}2 /mnt/new
rsync -avHAX / /mnt/new/ --exclude=/boot --exclude=/mnt --exclude=/dev --exclude=/proc --exclude=/sys
mkdir -p /mnt/new/{boot,mnt,dev,proc,sys}
mount ${TARGET_DEVICE}1 /mnt/new/boot

# edit /mnt/new/boot/cmdline.txt and change "root=/dev/mmcblk0p1" to "root=/dev/sda2"
# edit /mnt/new/etc/fstab and change the lines with /dev/mmcblk0* to use /dev/sda* instead.
```

#### Create encrypted data partition

Remove SD card and reboot.

```bash
TARGET_DEVICE=/enter/target/device/here
CRYPTO_PARTITION=${TARGET_DEVICE}4
sudo apt install busybox cryptsetup initramfs-tools
# check algorithm
cryptsetup benchmark -c xchacha20,aes-adiantum-plain64
# load kernel modules
sudo modprobe xchacha20
sudo modprobe adiantum
sudo modprobe nhpoly1305
sudo cryptsetup luksFormat --type luks2 --cipher xchacha20,aes-adiantum-plain64 --hash sha256 --key-size 256 $CRYPTO_PARTITION
sudo cryptsetup luksOpen $CRYPTO_PARTITION datapart
sudo mkfs.ext4 /dev/mapper/datapart
sudo mkdir /media/datapart
sudo mount /dev/mapper/datapart /media/datapart
sudo chown -R $(whoami):$(whoami) /media/datapart
```

### Variant 2: Full encryption (password required at boot)

> still to do

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
# copy /etc/rancher/k3s/k3s.yaml to control machine
```

Copy /etc/rancher/k3s/k3s.yaml to control machine and check status:

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
