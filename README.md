# Internal Wi-Fi (MediaTek MT7921) on PS5 Linux

Working internal Wi-Fi for PS5 consoles that have a **MediaTek MT7921** wireless chip instead of the Marvell chip, running Ubuntu via [ps5-linux-loader](https://github.com/soniciso1/ps5-linux-loader).

The project FAQ currently says WLAN only works on Marvell chipsets. On MT7921 consoles, the chip can actually be made to work with two changes:

1. Build the `mt7921e` PCIe driver, which the stock kernel config leaves out.
2. Disable the driver's runtime power management and deep sleep. Otherwise, the chip's low-power transition takes down the whole Salina southbridge (USB, Ethernet and Wi-Fi together) and the console powers off.

With both changes, the chip loads its firmware, connects through the normal Ubuntu network UI, auto-connects at boot before login, and held about 18 Mbps on a sustained download in testing.

## Does this apply to your console?

```bash
lspci -nnk -s 40:00.7
```

If you see this, this fix is for you:

```
40:00.7 Network controller [0280]: MEDIATEK Corp. MT7921 802.11ax PCIe Wireless Network Adapter [Filogic 330] [14c3:7961]
```

If `40:00.7` is a Marvell device, use the project's official `ps5-linux-mwifiex` driver instead.

## Tested setup

| | |
|---|---|
| Loader | soniciso1/ps5-linux-loader, provided Ubuntu image |
| Kernel | 7.1.7 (built with GCC 14.2) |
| Wi-Fi | MediaTek MT7921 `[14c3:7961]` at `40:00.7`, ASIC rev `79610010` |
| Firmware | `WIFI_RAM_CODE_MT7961_1.bin`, build 20260224 (from Ubuntu's linux-firmware) |
| PS5 model | *fill in* |

## What goes wrong, and why

### Problem 1: the driver isn't built

The kernel already ships nearly all of the MediaTek stack as modules. It only lacks the PCIe front end:

```
CONFIG_MT76_CORE=m
CONFIG_MT76_CONNAC_LIB=m
CONFIG_MT792x_LIB=m
CONFIG_MT7921_COMMON=m
# CONFIG_MT7921E is not set     <-- missing
CONFIG_MT7925E=m                <-- PS5 Pro chip, enabled
```

Because the shared libraries are already there, `mt7921e.ko` can be built out-of-tree against the installed kernel headers.

### Problem 2: the stock driver crashes the console

With an unmodified `mt7921e`, the PCIe side works fine. The driver binds, reads the chip, and loads both firmware stages. About one second later, the console powers off completely. A kernel log captured to disk shows what happens:

```
[112.814] mt7921e 0000:40:00.7: ASIC revision: 79610010
[112.891] mt7921e 0000:40:00.7: HW/SW Version: 0x8a108a10, Build Time: 20260224110909a
[112.904] mt7921e 0000:40:00.7: WM Firmware Version: ____010000, Build Time: 20260224110949
[114.124] xhci_hcd 0000:40:00.6: xHCI host controller not responding, assume dead
[114.153] mts 0000:40:00.2 enp64s0f2: link up (reg=0xffffffff)
[114.153] mts: enp64s0f2: HW error 0x7be600 lso-fifo-empty lso-proto rx-axi ...
[114.153] xhci_hcd 0000:40:00.6: HC died; cleaning up
          (console powers off)
```

`40:00.2` (Ethernet), `40:00.6` (USB) and `40:00.7` (Wi-Fi) are all functions of the same device, the **Salina southbridge**. Right after the Wi-Fi firmware starts, the whole southbridge stops responding: registers read back as `0xffffffff` and the USB controller dies. Since Ubuntu runs from a USB drive behind that controller, the system loses its root filesystem and the console shuts down.

Things that were ruled out:

- **Firmware loading itself.** Both firmware stages load successfully before the failure.
- **Host-side PCIe ASPM.** Loading with `disable_aspm=1` made no difference.
- **The USB Wi-Fi dongle.** It uses a separate driver on a different bus, and the crash happens without it.

What fixed it: turning off the driver's runtime power management (`pm.enable`) and deep sleep (`ds_enable`) defaults in `mt7921/init.c`. With these off, the driver no longer hands control to the chip firmware to enter low-power states, and it tells the firmware not to deep-sleep. The chip has run stably since, including across reboots and sustained transfers.

The two settings were disabled together, so it's not yet known whether only one of them is responsible. See [Open questions](#open-questions).

## Install

### Option A: script

[`build-mt7921e.sh`](build-mt7921e.sh) downloads the matching kernel source, verifies its checksum, applies the power-management change, and builds both modules.

```bash
chmod +x build-mt7921e.sh

# 1. Build only (nothing is installed)
./build-mt7921e.sh

# 2. Test by hand (see "Testing safely" below)

# 3. Once it's stable, install so it loads at boot
./build-mt7921e.sh --install
```

### Option B: manual steps

You need internet access during the build: wired Ethernet, a USB Wi-Fi dongle, or phone USB tethering.

**1. Install a compiler matching the kernel's.** The image's kernel was built with GCC 14, so:

```bash
grep CC_VERSION_TEXT /boot/config-$(uname -r)
sudo apt install -y build-essential gcc-14 wget xz-utils
```

**2. Get the mt76 source for your kernel version.**

```bash
KVER=$(uname -r)
mkdir -p ~/mt7921e && cd ~/mt7921e
wget https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KVER.tar.xz
wget -O sha256sums.asc https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc
grep " linux-$KVER.tar.xz$" sha256sums.asc | sha256sum -c -
tar xf linux-$KVER.tar.xz linux-$KVER/drivers/net/wireless/mediatek/mt76
cp -r linux-$KVER/drivers/net/wireless/mediatek/mt76 .
cd mt76/mt7921
```

**3. Disable runtime PM and deep sleep.**

```bash
sed -i -E 's/(pm\.(enable|enable_user|ds_enable|ds_enable_user)[[:space:]]*=[[:space:]]*)true/\1false/' init.c
grep -nE 'pm\.(enable|enable_user|ds_enable|ds_enable_user)' init.c
```

All four assignments must now say `false`:

```
dev->pm.enable_user = false;
dev->pm.enable = false;
dev->pm.ds_enable_user = false;
dev->pm.ds_enable = false;
```

**4. Build `mt7921-common` and `mt7921e`.**

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD CC=gcc-14 \
     CONFIG_MT7921E=m CONFIG_MT7921_COMMON=m modules
```

Warnings about the compiler patch version or pahole version differing, and "Skipping BTF generation", are expected and harmless. The build also produces `mt7921u.ko`, which you can ignore.

### Testing safely

Load the modules by hand first. If anything goes wrong, a reboot comes back clean because nothing is installed yet.

```bash
sync
sudo rmmod mt7921e mt7921-common 2>/dev/null
sudo modprobe -a mt76 mt76-connac-lib mt792x-lib
sudo insmod ./mt7921-common.ko
sudo insmod ./mt7921e.ko disable_aspm=1
sleep 20
sudo dmesg | grep -iE 'mt79|40:00' | tail
ip link
```

Success looks like:

```
mt7921e 0000:40:00.7: WM Firmware Version: ____010000, Build Time: ...
mt7921e 0000:40:00.7 wlp64s0f7: renamed from wlan0
```

Then connect from the Ubuntu network menu, or with `nmcli dev wifi connect "<SSID>" password "<pass>" ifname wlp64s0f7`, and run a large download to stress it.

### Installing permanently

Only do this after it has been stable in use. Once installed, the driver loads at every boot.

```bash
sudo mkdir -p /lib/modules/$(uname -r)/updates
sudo cp mt7921-common.ko mt7921e.ko /lib/modules/$(uname -r)/updates/
echo "options mt7921e disable_aspm=1" | sudo tee /etc/modprobe.d/mt7921e.conf
sudo depmod -a
modinfo -n mt7921_common mt7921e
```

Both paths must end in `updates/...`. That directory takes priority over `kernel/`, so the patched `mt7921-common` replaces the stock one. If `mt7921_common` still resolves to `kernel/...`, do **not** reboot: the stock version with power management on would load and crash the console at boot.

Also check that the initramfs doesn't contain a stock copy:

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep -i mt79
```

Only `etc/modprobe.d/mt7921e.conf` is fine. Any `.ko` file means you should run `sudo update-initramfs -u -k $(uname -r)`.

After a reboot:

```bash
modinfo -n mt7921_common                          # .../updates/mt7921-common.ko
cat /sys/module/mt7921e/parameters/disable_aspm   # Y
```

Wi-Fi should come up and auto-connect before you log in.

## Recovery

If the console ever shuts down during boot after installing, mount the Ubuntu USB drive on another Linux PC and delete:

```
lib/modules/7.1.7/updates/mt7921-common.ko
lib/modules/7.1.7/updates/mt7921e.ko
```

The system will then boot with the stock modules, and since the stock config has no `mt7921e`, the chip stays idle.

## Kernel updates

These modules are built for one exact kernel. If you move to a loader or image with a different kernel version, rebuild with the same steps, including the `init.c` change.

## Debugging tip: capturing logs across a hard power-off

`dmesg` is lost when the console cuts power, and netconsole can be awkward to set up. This writes every kernel message straight to disk as it happens:

```bash
sudo dd if=/dev/kmsg of=/var/log/kmsg-capture.log bs=8192 \
     oflag=sync,append conv=notrunc status=none
```

Run it in a separate terminal before the test. After rebooting, `tail -50 /var/log/kmsg-capture.log` shows the last messages before the crash. The USB drive's own write cache can still lose the final line or two.

## Open questions

- **Which setting is responsible?** It's not yet known whether runtime PM (`pm.enable`), deep sleep (`ds_enable`), or both trigger the southbridge failure. Testing them separately would show whether some power saving can safely stay on.
- **Is there a Salina-specific fix?** The PS5 Pro's MT7925 uses similar power management. If the official kernel changes anything for the MT7925 to avoid this, the same approach may let the MT7921 keep power saving enabled.
- **Bluetooth** hasn't been tested.

## Suggested upstream change

For ps5-linux kernel builds:

1. Enable `CONFIG_MT7921E=m`.
2. Default runtime PM and deep sleep to off for MT7921 devices on the Salina southbridge. This could be done with the `init.c` change above, or with a platform or PCI quirk so non-PS5 builds are unaffected.

## Credits

- The ps5-linux / ps5-linux-loader developers, for the Salina drivers and Ubuntu image that make any of this possible.
- The upstream Linux `mt76` driver maintainers.

---

## Easy install: prebuilt package

If you are on the stock ps5-linux-loader Ubuntu image (kernel 7.1.7), you do not need to build anything. Download `ps5-mt7921-wifi-7.1.7.zip` from this repo's **Releases** page. It contains a `.deb` with the patched, prebuilt driver and an `install.sh` that checks your system and installs it. No compiler or internet connection is needed.

### Requirements

- **Kernel 7.1.7**, the kernel in the ps5-linux-loader Ubuntu image. Check with `uname -r`.
- **A MediaTek MT7921 chip.** Check with:

  ```bash
  lspci -nn -s 40:00.7
  ```

  You need to see `MEDIATEK Corp. MT7921 ... [14c3:7961]`. If it says Marvell, this package isn't for you; use the project's official Marvell driver instead.
- **MediaTek firmware**, which the Ubuntu image already includes (`/lib/firmware/mediatek/WIFI_RAM_CODE_MT7961_1.bin*`).

The installer checks all three and stops if anything doesn't match.

### Install

1. Copy the zip onto the PS5's Ubuntu install, for example from a USB stick or with a browser download.
2. Unzip it and run the installer:

   ```bash
   unzip ps5-mt7921-wifi-7.1.7.zip -d ps5-wifi
   cd ps5-wifi
   bash install.sh
   ```

   Enter your password when asked.
3. When it says **"You need to reboot for it to take effect"**, reboot whenever you're ready. The installer never reboots on its own.
4. After rebooting, connect to your network from the Wi-Fi menu in the top-right corner, like on any Ubuntu PC. Once connected, it reconnects automatically on every boot.

### Check that it's working

```bash
ip link | grep wlp
cat /sys/module/mt7921e/parameters/disable_aspm
```

You should see a `wlp64s0f7` interface (the name may vary slightly) and `Y`.

### Uninstall

```bash
sudo apt purge ps5-mt7921-wifi
```

Then reboot. The internal Wi-Fi goes back to being unused, exactly as before.

### Troubleshooting

**The installer says "Do NOT reboot".** Something didn't install correctly. Run `sudo apt purge ps5-mt7921-wifi` to remove it, then report the installer's output.

**The console shuts off during boot after installing.** This shouldn't happen, but if it does, plug the Ubuntu USB drive into another Linux computer and delete these two files from it:

```
usr/lib/modules/7.1.7/updates/mt7921-common.ko
usr/lib/modules/7.1.7/updates/mt7921e.ko
```

The PS5 will then boot normally without the driver. Please report what happened.

**No Wi-Fi networks show up.** Run `sudo dmesg | grep -i mt79`. A line starting `WM Firmware Version` means the driver loaded. If you see firmware errors instead, check that the firmware files listed under Requirements exist.

### Good to know

- **Power saving is disabled on the Wi-Fi chip.** That's the fix: with power saving on, the chip crashes the PS5's southbridge and the console shuts off. The extra power use is negligible on a plugged-in console.
- **Only works with kernel 7.1.7.** If a future ps5-linux-loader image uses a different kernel, this package will refuse to install, and a new build is needed.
- **Disabling system sleep is recommended.** Suspend isn't supported on PS5 Linux. To turn it off completely:

  ```bash
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
  ```
