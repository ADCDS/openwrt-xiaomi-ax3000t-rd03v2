# Runtime opt-out from the custom memory guard

`nss-pool-boost-monitor` is the exact tested replacement userspace script with
`MEMORY_GUARD=0`. It is **not** an NSS firmware setting, Linux MEMCG option or a
change to the preserved image. The stock laboratory image still has its guard.

The replacement bypasses only the32MiB startup and24MiB running MemAvailable
checks; board/rootfs, Wi-Fi/low-water, extra-pbuf and high-water readback checks
remain. The status includes `memory_guard=0`. The service still resets high-water
on stop or a non-memory validation failure.

Copy this replacement to `/tmp/nss-pool-boost-monitor.new` on a test RD03v2
already using the matching custom service. Back up its original script, then:

```sh
sh -n /tmp/nss-pool-boost-monitor.new &&
    /etc/init.d/nss-pool-boost stop &&
    cp /tmp/nss-pool-boost-monitor.new /usr/sbin/nss-pool-boost-monitor &&
    chmod 755 /usr/sbin/nss-pool-boost-monitor &&
    rm -f /etc/nss-pool-boost.failed &&
    /etc/init.d/nss-pool-boost start
```

Wait approximately52seconds for the ramp, then inspect:

```sh
cat /tmp/nss-pool-boost.status
cat /proc/sys/dev/nss/n2hcfg/n2h_high_water_core0
```

Expected: `ACTIVE high=30258 ... memory_guard=0`. In this replacement,
`MEMORY_GUARD=1` restores the two memory checks after a service restart.
The original unmodified script has no such variable, so changing a variable
alone in that original script does not implement this opt-out.

This modifies the writable overlay and persists across reboot, but preservation
across a later sysupgrade is not automatic. RAM-recovery boots are still skipped.
Keep OOM/SSH/kernel monitoring during stress tests: zram cannot swap out NSS
payload storage or unreclaimable Slab. Guard-off is an experimental choice.
