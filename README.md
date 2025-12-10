# Encrypted High Availability Raspberry Pi Cluster for Dummies

## Disclaimer

> :warning: **You perform all scripts, commands and actions and use all information listed here entirely at your own risk.** :warning:

This is a work in progress. It is currently incomplete.

## Goals

- Set up a high availability [K3s](https://k3s.io/) cluster on multiple [Raspberry Pi](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) single-board computers
- Individual nodes should be fully encrypted using [LUKS](https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup)
- Nodes boot from GPT partitioned disks connected via USB 3 (SD card / USB stick used only during installation)
- Used for home automation and distributed backups

### Hardware

- [Raspberry Pi 4 Model B](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/) (8 GB RAM)
- Geekworm [X832](https://wiki.geekworm.com/X832) board
- Geekworm [X735](https://wiki.geekworm.com/X735) cooling fan
- Geekworm [X832-C1](https://wiki.geekworm.com/X832-C1) case
- 12V 5A AC/DC power adapter, 5.5 x 2.5 mm round DC plug (compatible to 5.5 mm x 2.1 mm)
- 3.5" SATA harddisk

### Software

Tested with [Raspberry Pi 64-bit Lite OS 13 ("Trixie")](https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64.img.xz)

## Clone Repo & Set Up Dependencies

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

## Individual Node Setup

### Flash Raspberry Pi OS to USB Drive

- Use [Raspberry Pi Imager](https://downloads.raspberrypi.org/imager/) to flash [Raspberry Pi OS](https://downloads.raspberrypi.com/raspios_lite_arm64/images/) to a USB drive.

#### Customize Raspberry Pi OS

**If customizing the installation medium via the imager did not work**, the script [pi-config.sh](pi-config.sh) may be used:

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

Boot the Pi with the USB drive you just created, it will restart multiple times. When you can log in via SSH, update the firmware, which is needed for booting from GPT partitioned disks.

```bash
sudo apt-get update
sudo apt-get -y dist-upgrade
sudo apt-get -y install rpi-eeprom
sudo rpi-eeprom-update -a
sudo reboot
```

The Pi will reboot and upgrade the firmware, if necessary.

### Prepare for transferring OS to HDD

#### Set Target Drive and Encryption Passphrase

Connect the target HDD to the Pi and check which device you want to install the OS to. This could be `/dev/sdb` for example. :warning: WARNING: THIS DRIVE WILL BE COMPLETELY OVERWRITTEN, DOUBLE CHECK THIS! :warning:

Create [roles/os_transfer/defaults/main.yml](roles/os_transfer/defaults/main.yml) and set your values:

```yaml
---
target_drive: "/dev/sdb"    # THIS DRIVE WILL BE COMPLETELY OVERWRITTEN, DOUBLE CHECK THIS!
luks_passphrase: "changeme" # the passphrase with which the HDD will be encrypted
mount_point: "/mnt/chroot"  # no need to change this
```

#### Create Inventory File

Create a [hosts](hosts) file with the hostname you chose for the Pi:

```yaml
[k3snodes]
piHostname
```

### Transfer OS to HDD

With the target disk connected to the Pi, run the `os_transfer` playbook **on your control machine, not on the Pi**:

```bash
ansible-playbook -u 'username_on_pi' -i hosts os_transfer.yml --ask-become-pass
```

If the playbook ran successfully (check the output!), the Pi will automatically shut down.

### Reboot from installed OS

Remove the installation medium (USB drive) from the Pi and reboot with the target drive still connected. The Pi should boot the Dropbear SSH server. Connect by `ssh -p 2222 root@<IP ADDRESS OF PI>`.

When connected, run `cryptroot-unlock` and enter the decryption password when prompted, then the Pi should fully boot into the OS. Test by connecting: `ssh username_on_pi@piHostname`.

### Apply Playbooks

```bash
ansible-playbook -u 'username_on_pi' -i hosts site.yml --ask-become-pass
```
