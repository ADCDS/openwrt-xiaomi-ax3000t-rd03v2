# Rejected candidates

## 0921-private-qcom-mdt-zero-the-bss-on-a-user-pd-reload.patch

Zeroing a user PD's bss from the host during an in-place reload resets the
board. The write goes through `wcss->mem_region` (a write-combining ioremap of
the Q6's reserved DDR) while the **root PD is still running**, and the region is
protected by the Q6's access control: on the RD03v2 bench the board reset about
15 ms after `PD reload begin`, with no kernel log at all, which is the same
signature v1 documented for a root-PD crash that resets the board.

The diagnosis behind it still stands and is worth keeping: `__qcom_mdt_load()`
skips its bss memset for the secure path, because the 0919 candidate added
`!dma_required &&` to that condition, so a reloaded PD starts on the previous
firmware's bss. Measured on b10d2: the PD spawns and reports ready but never
prints `chip_id`/`fw_version`, its QMI server never comes up, ath11k waits out
its firmware start and the root Q6 takes a fatal error.

A viable fix has to clear that memory **through the secure loader**, which runs
with the access rights the host lacks - for instance by issuing a PAS segment
load of zeroed data for the ranges that have no file data. Re-doing it with a
host memset will reset the board again.
