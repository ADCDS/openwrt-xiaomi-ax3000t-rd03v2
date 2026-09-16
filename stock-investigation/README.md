# stock-investigation

Live inspection of a **stock** Xiaomi RD03v2 (ROM 2.0.28, Linux 4.4.60 armv7l)
on the bench at `192.168.31.1`, executing [`STOCK-LIVE-ITINERARY.md`](STOCK-LIVE-ITINERARY.md).

Stock had never been inspected on hardware before this
(`ax3000t-firmware/ROOT_ASSESSMENT.md`); everything the project knew about stock
came from the offline rootfs extraction. This folder is the first set of numbers
that only a running box can give.

## Read this first

- **[`notes/FINDINGS.md`](notes/FINDINGS.md)** — Q1–Q7 answered, phase by phase,
  with the port-side follow-up for each.
- **[`notes/Q1-MEMORY.md`](notes/Q1-MEMORY.md)** — the memory question in full:
  why stock idles with ~66 MB available where our v1.8 has ~32 MB.
- **[`notes/RSSI-VS-STOCK.md`](notes/RSSI-VS-STOCK.md)** — issue #3 re-checked
  against stock: noise floor and 2.4 GHz are fixed, 5 GHz reads ~8 dB hot.
- **[`notes/V1.9-TUNING.md`](notes/V1.9-TUNING.md)** — what to change in `main`
  before v1.9 ships, ranked by megabytes per unit of risk, with the exact file
  for each.

## Layout

```
STOCK-LIVE-ITINERARY.md   the plan this executed
scripts/     one read-only script per phase, plus the ssh helpers
captures/    scrubbed output, committed
raw/         unscrubbed output, gitignored (holds serial, MIoT key, MACs, SSIDs)
notes/       the analysis
```

`captures/` is produced from `raw/` by `scripts/scrub.sh`, which strips MAC
addresses, the serial number, MIoT device id/key, the nvram random keys, SSIDs
and the bench password, then greps the result to prove they are gone. Re-run it
after any new capture.

## Running it again

Credentials live in `.bench-env`, which is gitignored — a fresh clone will not
have it. Create it first, or the helpers refuse to run:

```sh
cat > .bench-env <<'EOF'
STOCK_PASS=<bench root password>
BENCH_PSK=<bench AP PSK; only needed to attach a client for phase 8>
BENCH_PASS=<dev bench root password; only needed by bsh, see below>
EOF
chmod 600 .bench-env
```

`scrub.sh` reads the same file, so those secrets get stripped from `captures/`
without any of them being written into a tracked script.

```sh
cd scripts
./rsh 'uptime'                 # one-off command on the bench unit
./rrun phase1.sh > ../raw/phase1-memlayout.txt
./psh  'uptime'                # read-only, on the port-side reference AP
./bsh  'uptime'                # dev bench (our unit under test), over the wire
./scrub.sh
```

| helper | target | notes |
|---|---|---|
| `rsh` | bench stock unit, `192.168.31.1` | password auth via `sshpass`, credentials from `.bench-env`; override with `STOCK_HOST`/`STOCK_PASS` |
| `rrun <script>` | same | stages the script in `/tmp` and runs it with stdin closed, then deletes it |
| `psh` | port reference AP, `192.168.100.2` | key auth (`~/.ssh/id_router`) |
| `bsh` | dev bench port unit, `192.168.1.1` | **writable** — this is the box we reflash. Forces the wired path (see below) |

`rsh` and `psh` are read-only by policy. `bsh` is not: the dev bench is ours to
reflash, poke sysctls on, and reboot.

**`bsh` forces the wired link.** The USB3 ethernet to the dev bench lives in a
root-owned `bench` network namespace, so `bsh` runs everything under
`ip netns exec` (hence sudo). Outside that namespace the only route to the bench
is over WiFi — the very link a reflash tears down. The bench-side address is
static (`192.168.1.50`, deliberately outside the `.100`-`.249` DHCP pool) so the
control path cannot expire or be reassigned mid-flash; `bsh` refuses to run if
that address is missing rather than quietly falling back to WiFi.

**Use `rrun`, not `rsh < script`, for anything that might read stdin.** Piping a
script into `ssh 'sh -s'` makes the script itself the remote shell's stdin, so a
command like bare `bdata` swallows the rest of the file and hangs. That is how
the first phase 6 run died.

The host's `/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` has permissions ssh
refuses, so all three helpers pass `-F /dev/null` (or `-F ~/.ssh/config`) to skip
the system config.

## Ground rules that were followed

- **No flash writes.** No `mtd write`, `nvram set`/`commit`, `bdata set`/`commit`,
  `fw_setenv`, or UCI commit. `devmem` was used for reads only.
- **No reboot.** Uptime was continuous across every capture, so the box never ran
  `boot_check`'s `nvram commit`.
- **Box kept off the internet.** It has no default route and no WAN uplink; the
  anti-rollback floor cannot move.
- **Streamed to the host**, never accumulated in the RAM-backed `/tmp`.
- **The port-side AP at `192.168.100.2` is in service as backhaul** and was only
  ever read from.
- **Teardown verified**: boot flags, ROM version, subsystem crash counts and
  `dynamic_debug` all identical to phase 0 afterwards.

## Coverage

| phase | state |
|---|---|
| 0 identity, boot flags, live DTB | done |
| 1 memory layout | done |
| 2 idle memory breakdown | done, with a caveat (no `CONFIG_SLUB_DEBUG`, so no per-cache data) |
| 3 Wi-Fi driver state | done |
| 4 NSS core and ECM | done |
| 5 switch and GMAC | done |
| 6 nvram / `boot_wait` | done |
| 7a restart policy (read-only) | done |
| 7c crash injection | **not run** — disruptive |
| 8 load test | **partial** — 5 GHz RX only; the bench has no wired host on the stock unit's LAN, so forwarded 5 GHz↔wired traffic could not be generated |
| 0b offline kernel disassembly | not run |

Phase 8 borrowed `hal` as a 5 GHz client and restored it afterwards (interface
down, prior address, no leftover processes). The bench unit's only residue is a
DHCP lease for `hal` in `/tmp/dhcp.leases`, which is RAM-backed and expires.

Two itinerary assumptions did not survive contact and are worth fixing there:

- **`/proc/slabinfo` does not exist on stock** (`CONFIG_SLUB` without
  `CONFIG_SLUB_DEBUG`), and our own build is the same. Phase 2's "compare slab
  caches one by one by object count" cannot be done on either side without a
  kernel rebuild.
- **The dmesg ring had already wrapped at 58 minutes uptime.** No boot-time line
  survives to be grepped. Phase 0's `dmesg > dmesg-boot.txt` only works from a
  cold boot or over UART.

A third, milder one: the live device tree is **not** `stock_mp03.3.dts`. The
bootloader drops the `qcn9000_pcie0` and `dma_pool1` reservations. Use
`captures/live.dts`.
