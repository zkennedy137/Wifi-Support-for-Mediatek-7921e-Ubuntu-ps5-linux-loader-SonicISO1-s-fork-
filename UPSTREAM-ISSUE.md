**Title:** MediaTek MT7921 internal Wi-Fi works with `CONFIG_MT7921E=m` + runtime PM disabled (fix for Salina southbridge crash)

---

### Summary

The FAQ says WLAN is only supported on Marvell chipsets. I have a console with a **MediaTek MT7921** at `40:00.7`, and I got its internal Wi-Fi fully working on the provided Ubuntu image (kernel 7.1.7). It loads at boot, auto-connects, and is stable under sustained transfers.

Two changes were needed:

1. **`CONFIG_MT7921E` isn't set.** All the shared modules are already built (`MT76_CORE`, `MT76_CONNAC_LIB`, `MT792x_LIB`, `MT7921_COMMON`, and `MT7925E` for the Pro), so only the PCIe front end is missing.
2. **Runtime PM and deep sleep must be disabled.** With the stock driver, the firmware loads, then about a second later the whole Salina southbridge stops responding and the console powers off.

### Hardware

```
40:00.7 Network controller [0280]: MEDIATEK Corp. MT7921 802.11ax PCIe Wireless Network Adapter [Filogic 330] [14c3:7961]
ASIC revision: 79610010
PS5 model: <fill in>
```

### Crash with the stock driver

Captured by writing `/dev/kmsg` to disk with `O_SYNC`:

```
[112.904] mt7921e 0000:40:00.7: WM Firmware Version: ____010000, Build Time: 20260224110949
[114.124] xhci_hcd 0000:40:00.6: xHCI host controller not responding, assume dead
[114.153] mts 0000:40:00.2 enp64s0f2: link up (reg=0xffffffff)
[114.153] mts: enp64s0f2: HW error 0x7be600 lso-fifo-empty lso-proto rx-axi ip-cksum tcp-cksum udp-cksum rx-pcode
[114.153] xhci_hcd 0000:40:00.6: HC died; cleaning up
          (console powers off)
```

Ethernet (`40:00.2`) and USB (`40:00.6`) go down together about one second after the Wi-Fi firmware starts. `disable_aspm=1` doesn't help.

### Fix

In `drivers/net/wireless/mediatek/mt76/mt7921/init.c`, set the PM defaults to `false`:

```c
dev->pm.enable_user = false;
dev->pm.enable = false;
dev->pm.ds_enable_user = false;
dev->pm.ds_enable = false;
```

Then build `mt7921-common` and `mt7921e`. With this change, the chip comes up as `wlp64s0f7`, connects through NetworkManager, and has been stable across reboots and sustained downloads.

Full write-up, build script, and recovery steps: **<link to your repo>**

### Suggested change for the kernel build

- Enable `CONFIG_MT7921E=m`.
- Default runtime PM and deep sleep to off for MT7921 on Salina. A platform or PCI quirk would keep this from affecting non-PS5 builds.

I haven't yet tested whether `pm.enable` or `ds_enable` alone is responsible. If the MT7925 on the Pro needed a Salina-specific change to avoid the same failure, that might let the MT7921 keep some power saving. I'm happy to test patches.
