# Building

```sh
git clone https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2.git
cd openwrt-xiaomi-ax3000t-rd03v2
TAG=DEV-<name> ./build.sh            # or a release tag; PREPARE_ONLY=1 stops before make
```

- The workspace is this repository plus, next to it: `mirrors/` (kuncy7's tree and his nss feed,
  never pruned, with reflogs), `keys/v2/` (the signing key), `dl-v2/` (the download cache),
  `ccache-v2/`, `v2-tmp/` (scratch space), `v2-validation/` (the lock that keeps builds and
  bench runs apart), `pages-worktree/` (the `gh-pages` worktree `publish-repo.sh` fills) and
  a checkout of [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install)
  (`verify-artifacts.py` uses its image checks). `RD03V2_WS` points elsewhere; each path
  also has its own variable. The build tree defaults to `openwrt-v2/` and release assets to
  `rel-v2-<tag>/`, both inside the repository and ignored by git.
- `upstream.lock`: his release and commit. His CI keeps only three releases and his branches
  get rebased, so the commits a release of ours builds on live in our forks, tagged
  `rd03v2/<his release>`: [ADCDS/openwrt](https://github.com/ADCDS/openwrt) (his tree; the fork
  in his fork network) and [ADCDS/nss-packages](https://github.com/ADCDS/nss-packages) (his nss
  feed). The build reads the local mirrors and fills them from the forks when a pinned commit
  is missing, so a fresh workspace builds from the forks alone.
  `tools/bump-upstream.sh <release>` takes a new release from his repositories, tags its
  commits in the mirrors and, with `PUSH_PINS=1`, pushes the tags to the forks.
- `feeds.lock`: every feed pinned to a commit: the ones his CI built our board group with,
  from the `feeds-256m.buildinfo` it attaches to each release (`tools/freeze-feeds.sh` picks
  them by date for a release without one).
- `tree-patches/`: our changes to his files, applied with `git am` (no fuzz).
- `overlay/`: new files only; the build refuses to overwrite his.
- `config/`: his CI fragments for the 256 MB group are used as they are; ours follow.
- `tools/verify-v2.sh --tree` checks the result; the build fails on any FAIL.
