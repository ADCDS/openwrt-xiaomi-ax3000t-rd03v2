# Pinned v1.10 NSS Wi-Fi laboratory source snapshot

The experimental images discussed in [issue #18](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/issues/18) were assembled from more than the upstream builder defaults. This directory publishes the source inputs for the **later MEMCG=n GCC build**, so reviewers can inspect and prepare the same kernel, feeds, patches and configuration.

It does not modify the repository's default build, replace the Qualcomm firmware blob, or claim that the Wi-Fi starvation/REO problem is solved. It is an opt-in laboratory snapshot, not a proposal to disable memory cgroups globally.

## Which binary?

- Sysupgrade SHA256: `f6855e4b7d4b798aad583b3afbda8d22dc1766fb5c4584df9d663afb11c2eba6`
- This is **not** the earlier published `344d318b...` statistics image.
- GCC `-Os`, `NR_CPUS=2`, `MEMCG=n`; kernel and package LTO disabled. The rejected Clang/Oz experiment is excluded.
- `manifest.json` pins OpenWrt and all seven feed commits and hashes every tracked diff and added source file. `build.config` is the archived configuration used for that image; `kernel.config.reference` is its generated Linux configuration.
- The image's memory guard is **enabled**. The subsequently tested guard-off modification lives separately under `runtime/`; applying it changes the running system, not these original source inputs or binary checksums.

The snapshot preserves source inputs; a second full build from this reconstruction script has not been compared bit for bit with the binary. Build host/tool versions, timestamps and downloaded sources can affect reproducibility. `image-verification.json` describes the 121 offline checks performed on the original successful clean build; it is not a substitute for validating a new build.

Reconstruction was exercised in a new Linux tree using local reference Git objects: all eight commits, tracked diffs, 196 added files and their modes matched; feed indexing/install and `make defconfig` produced no effective configuration changes. The pinned feeds emitted three Kconfig recursive-dependency diagnostics for unselected package options (including librespeed and squeezelite). These diagnostics are not fixed by this snapshot; it is not advertised as a warning-free new build. See `source-verification.json`.

## Changes retained in this experimental configuration

- NSS Wi-Fi integration, native v1.10 BDF and existing DSA/ECM integration.
- Compact ath11k 256-MB host profile: 4 VDEVs, 64 stations (68 peer resources), effective TX completion ring 2048, RX refill1816, corresponding RX descriptor/TLV callbacks; firmware memory mode2. NSS connection-table profile remains MEDIUM.
- `scheme_id=255` failure sentinel and optional empty-buffer refill diagnostics.
- NSS12.5 peer-statistics ABI definition, per-peer/netdev accounting and diagnostics for LuCI counters.
- Gradual high-water30258 policy, low-water2048, Wi-Fi pool4096, extra-pbuf3100672; the original32/24MiB memory guard remains in the snapshot.
- NSS fixed1GHz, CPU performance policy, bounded32MiB zram (16MiB compressed allocation limit).
- Lean kernel configuration, Mesh retained, PPPoE retained; maximum CPU count2, size optimization and MEMCG off. Removing MEMCG also removes its PAGE_COUNTER, CGROUP_WRITEBACK and SLAB_OBJ_EXT dependencies.
- Initramfs build shell errors propagate, avoiding an apparently successful build when the RAM image link failed.

The full source diffs include the underlying v1.10 support, not just new changes versus v1.10. They are kept here to reconstruct pinned input trees without relying on a changing donor checkout. Original source/patch attribution and licensing notices are retained.

## Prepare and build in Linux / WSL2

Install the usual OpenWrt build prerequisites, Git and Python3, with ample disk space. From this directory:

```sh
python3 prepare.py --verify-only
python3 prepare.py "$HOME/rd03v2-memcg-off-rebuild"
cd "$HOME/rd03v2-memcg-off-rebuild"
make download -j20
make -j20 V=s 2>&1 | tee build.log
```

Use `set -o pipefail` in Bash when relying on the piped build exit status. `prepare.py` requires a new destination, checks source hashes, checks out pinned commits, applies tracked diffs and restores added files and their executable modes. It indexes the already pinned feeds without updating their revisions. It does not flash a router.

For offline source validation, `--reference-tree /path/to/existing/openwrt` can borrow that checkout's Git objects and its feeds. Such a checkout depends on the reference object store remaining available; use the default public URLs for an independent checkout. `--sources-only` skips feed indexing/defconfig.

After building, validate board/image metadata, initramfs contents, modules and image checksums before using the applicable device installation procedure. No private LAN, Wi-Fi credentials, host keys or router configuration backups are included here.

## Runtime memory-guard opt-out

See [runtime/README.md](runtime/README.md). Disabling the guard leaves the larger high-water in place even below24MiB available RAM; Linux OOM handling and zram still exist, but cannot guarantee recovery from NSS/kernel memory exhaustion.

## Measured limits

The original MEMCG=n image passed the recorded clean build/offline checks and was installed on a test RD03v2. Wired↔Wi-Fi TCP4 target500Mbps10s delivered499.6/499.5Mbps without new payload allocation failures. After opting out of the memory guard, same-radio PC↔S26 TCP4 target500Mbps15s delivered299.3/379.9Mbps; minimum free payload2054, minimum available memory15.35MiB, swap0. `wifili_wbm_src_reo_code_inv` increased973 across those two runs and remains unresolved.

Subsequent instrumentation found that an available-memory reduction of15204KiB coincided with SUnreclaim growth14724KiB and total NSS payload4500→11311, with unchanged file cache and only44KiB more anonymous process pages. Buffers and Slab declined after traffic. This supports transient kernel packet-buffer growth; it does not prove the absence of a longer-term leak or identify every slab allocation.

Long-duration, simultaneous bidirectional, multi-client and all possible recovery paths remain unverified. The MEMCG=y rollback comparison is recorded separately from these preserved MEMCG=n artifacts.
