# Encrypted High Availability Raspberry Pi Cluster for Dummies

## Disclaimer

> :warning: **You perform all scripts, commands and actions and use all information listed here entirely at your own risk.** :warning:

This is a work in progress. It is currently incomplete.

## What is this?

* high availability [K3s](https://k3s.io/) cluster (using [etcd](https://etcd.io/) and [kube-vip](https://kube-vip.io/))
* encrypted nodes (OS and storage) via [LUKS](https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup)
  * nodes can be decrypted via SSH during boot
* supports large HDDs (18TB+) via GPT partitioning
* valid certificates for secure communication (via [Let's Encrypt](https://letsencrypt.org/))
* distributed backups using one [SyncThing](https://syncthing.net/) instance on each node (as [DaemonSet](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/))

### Project Architecture

![](diagrams/Architecture.drawio.png)

### What do we need?

For each node:

- [Raspberry Pi 4 Model B](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) (8 GB RAM)
- Geekworm [X832](https://wiki.geekworm.com/X832) board
- Geekworm [X735](https://wiki.geekworm.com/X735) cooling fan
- Geekworm [X832-C1](https://wiki.geekworm.com/X832-C1) case
- 12V 5A AC/DC power adapter, 5.5 x 2.5 mm round DC plug (compatible to 5.5 mm x 2.1 mm)
- 3.5" SATA harddisk

For setup:
- an SD card or USB stick (referred to as "installation medium")
- a computer running Linux (referred to as "control machine")

### Preparation: IPv4 Addresses

Think about which IP addresses you want to assign to the cluster nodes. In this example, we will use
- `192.168.178.200` for the cluster control plane (virtual IP address, used by `kubectl`)
- `192.168.178.201` - `192.168.178.220` for the cluster nodes
- `192.168.178.221` - `192.168.178.254` for any applications running on the cluster

For this to work, you need to configure your home router to **not** assign these IP addresses to any device on your LAN. This can usually be done in the advanced network configuration (DHCP server) of your router, instructions vary by router brand and model.

## Setting up an encrypted Raspberry Pi Node

### Clone this Repo & Set Up Dependencies

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

### Flash Raspberry Pi OS to SD card or USB Drive

Use [Raspberry Pi Imager](https://downloads.raspberrypi.org/imager/) to flash [Raspberry Pi OS](https://downloads.raspberrypi.com/raspios_lite_arm64/images/) to a SD card orUSB drive. This guide has been tested with [Raspberry Pi 64-bit Lite OS 13 ("Trixie")](https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64.img.xz).

**Note: If the Raspberry Pi's firmware version is less than `pieeprom-2020-09-03`, booting from USB may not work. Use an SD card instead, we will update the firmware next (see [Update Raspberry Pi firmware](#update-raspberry-pi-firmware)).**

In the Imager, set your customization options (username, password, WiFi SSID and passphrase, country code, hostname, SSH authorized keys, etc.).
**If customizing the installation medium via the imager did not work**, the script [pi-config.sh](pi-config.sh) may be used.
> :warning: **Make sure that /path/to/bootfs_mount_dir and /path/to/rootfs_mount_dir are the correct paths to the mounted filesystems of the installation medium, else you may cause trouble on your control machine.** :warning:

```bash
sudo ./pi-config.sh \
  -u username_on_pi \
  -p supersecretpassword \
  -s wifiSSID \
  -w wifiPassphrase \
  -c 2digitCountryCode \
  -h piHostname \
  -k authorized_keys_file \
  -b /path/to/bootfs_mount_dir \
  -r /path/to/rootfs_mount_dir
```

### Update Raspberry Pi firmware

Boot the Pi with the installation medium you just created, it will restart multiple times. When you can log in via SSH, update the firmware, which is needed for booting from GPT partitioned disks via USB:

```bash
sudo apt-get update
sudo apt-get -y dist-upgrade
sudo apt-get -y install rpi-eeprom
sudo rpi-eeprom-update -a
sudo reboot
```

The Pi will reboot and upgrade the firmware if necessary.

### Prepare for transferring OS to HDD

#### Set Target Drive and Encryption Passphrase

Connect the target HDD to the Pi while it is still running and check which device you want to install the OS to. This could be `/dev/sdb` for example.
> :warning: **WARNING: THE TARGET DRIVE WILL BE COMPLETELY OVERWRITTEN, DOUBLE CHECK THIS!** :warning:

Create [roles/os_transfer/defaults/main.yml](roles/os_transfer/defaults/main.yml) and set your values:

```yaml
---
target_drive: "/dev/sdb"    # THIS DRIVE WILL BE COMPLETELY OVERWRITTEN, DOUBLE CHECK THIS!
luks_passphrase: "changeme" # the passphrase with which the HDD will be encrypted
mount_point: "/mnt/chroot"  # no need to change this
```

#### Create Inventory File

Create a [hosts](hosts) file with the hostname you chose for the Pi, the IP address you want to assign to it (chosen [here](#preparation-ipv4-addresses)) and the gateway of your LAN:

```yaml
[k3snodes]
piHostname static_ip_address=192.168.178.201/24 static_ip_gateway=192.168.178.1
```

### Transfer OS to HDD

With the target disk connected to the Pi, run the `os_transfer` playbook **on your control machine, not on the Pi**:

```bash
ansible-playbook -u 'username_on_pi' -i hosts os_transfer.yml --ask-become-pass
```

If the playbook ran successfully (check the output!), the Pi will automatically shut down.

### Reboot from installed OS

Remove/disconnect the installation medium from the Pi and boot with the target drive still connected. The Pi should boot the Dropbear SSH server. Connect from the control machine by `ssh -p 2222 root@<IP ADDRESS OF PI>`.
When authenticated by SSH key and successfully connected, the Pi automatically prompts for the LUKS passphrase. Enter the decryption passphrase when prompted, then the Pi should fully boot into the OS. Test by connecting: `ssh username_on_pi@piHostname`.

### Apply basic Config via Ansible Playbooks

Run the `site.yml` playbook **on your control machine, not on the Pi**:

```bash
ansible-playbook -u 'username_on_pi' -i hosts site.yml --ask-become-pass
```

This installs basic/convenient software on the Pi as well as some k3s prerequisites, for details see [basic](roles/basic/tasks/main.yml), [disable_swap](roles/disable_swap/tasks/main.yml), [zsh](roles/zsh/tasks/main.yml) and [x735](roles/x735/tasks/main.yml).

## Cluster Setup

### Install k3s

Connect to the Pi via SSH and run the following command. Replace `MySecretClusterToken` with a random string (this is your cluster token needed for administration and joining nodes to the cluster!) and `192.168.178.200` with the desired virtual IP address of the control plane (chosen [here](#preparation-ipv4-addresses)):

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=MySecretClusterToken sh -s - server \
  --cluster-init \
  --tls-san 192.168.178.200 \
  --disable servicelb \
  --disable traefik
```

### Install kube-vip

Source: [kube-vip docs](https://kube-vip.io/docs/installation/daemonset/)

Run as root on Pi:

```bash
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml
export VIP=192.168.178.200
export INTERFACE=eth0
export KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")
alias kube-vip="ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION; ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip"
kube-vip manifest daemonset \
    --interface $INTERFACE \
    --address $VIP \
    --inCluster \
    --taint \
    --controlplane \
    --services \
    --arp \
    --leaderElection > kube-vip-daemonset.yaml
kubectl apply -f kube-vip-daemonset.yaml
```

### Copy k3s config to control machine

On the Pi:

```bash
sudo cp /etc/rancher/k3s/k3s.yaml ~
sudo chown ${USER}:${USER} ~/.k3s.yaml
mkdir -p ~/.kube
mv ~/.k3s.yaml ~/.kube/config
```

On the control machine:

```bash
mkdir -p ~/.kube
scp pi@piHostname:~/.kube/config ~/.kube/config
```

On you control machine, edit `~/.kube/config` and modify the server ip:

```yaml
    server: https://127.0.0.1:6443
```

to the one you chose for the cluster ([chosen here](#preparation-ipv4-addresses)).

```yaml
    server: https://192.168.178.200:6443
```

You can now use `kubectl` to interact with the cluster from your control machine.

### Install Syncthing as DaemonSet

This will install a separate instance of syncthing on every node of the cluster, making it reachable via a port on the local node. SyncThing will configured to read/write directly onto the HDD of the node.

```bash
kubectl apply -f apps/syncthing/syncthing.yaml
```

### Add cluster nodes

Repeat the proccess for setting up another node including [customizing the installation medium again](#flash-raspberry-pi-os-to-sd-card-or-usb-drive) with a different hostname and IP address.
Connect to the new node via SSH and run the following command. Replace `MySecretClusterToken` with your clusters token ([chosen here](#install-k3s)) and `192.168.178.200` with the desired virtual IP address of the cluster ([chosen here](#preparation-ipv4-addresses)).

```bash
curl -sfL https://get.k3s.io | K3S_TOKEN=MySecretClusterToken sh -s - server \
  --server https://192.168.178.200:6443 \
  --tls-san 192.168.178.200 \
  --disable servicelb \
  --disable traefik
```

<!-- After this, `kubectl get nodes` should show the new node.

## Install Longhorn and Nginx Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.10.1/deploy/longhorn.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.1/deploy/static/provider/cloud/deploy.yaml
htpasswd -c auth longhorn-admin
kubectl -n longhorn-system create secret generic basic-auth --from-file=auth
``` -->
