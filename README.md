# pvr.hts.webos3

Cross-compiles the **Kodi `pvr.hts` (Tvheadend HTSP client) binary add-on** for
**LG webOS on 32-bit ARM (ARMv7)**, for Kodi webOS builds with
`ADDON_API 22.90.701` — i.e. the `org.xbmc.kodi_22.90.701_arm-WEBOS-3-plus`
Kodi build (xbmc/xbmc `master`, "Kodi 23.0-ALPHA1").

The output is `dist/pvr.hts-webos-armv7.zip`, a regular Kodi add-on zip that can
be copied into the Kodi app directory on the TV.

---

## Why this works

Kodi's official webOS build system is documented in
[`xbmc/xbmc/docs/README.webOS.md`](https://github.com/xbmc/xbmc/blob/master/docs/README.webOS.md).
This project automates exactly that flow:

1. Downloads the **`arm-webos-linux-gnueabi`** toolchain (buildroot-nc4, GCC 12.2,
   glibc 2.31, kernel 5.4.96 target — the same family Team Kodi's
   `webos-docker` CI uses) from
   [openlgtv/buildroot-nc4 releases](https://github.com/openlgtv/buildroot-nc4/releases).
2. Checks out **xbmc/xbmc** at the commit that carries `ADDON_API 22.90.701`.
3. Configures and builds `tools/depends` for
   `--host=arm-webos-linux-gnueabi` (webOS, GLES, `armeabi-v7a`).
4. Builds only the **`pvr.hts`** add-on through
   `tools/depends/target/binary-addons` (`ADDONS="pvr.hts"`). The source
   (`kodi-pvr/pvr.hts`, Kodi's add-on definition repository) is fetched
   automatically, and `addon.xml` is stamped with the PVR/binary API versions
   of the Kodi tree — which is what makes the add-on installable on the TV.
5. Packages the result as `pvr.hts-webos-armv7.zip`.

Because the add-on is compiled against the same Kodi source/API as the installed
build, the version checks Kodi performs at install time pass.

---

## Requirements

- Linux (Ubuntu/Debian recommended; the script installs build dependencies with
  `apt`). On other distros install the packages listed in `build.sh` manually
  and use `--no-deps`.
- ~15 GB free disk space.
- 2–4 CPU cores (more is better: this is a full Kodi dependency cross-build).
- Build time: roughly **1–3 hours on the first run**, a few minutes afterwards.

---

## Local build

```bash
git clone https://github.com/lazarh/pvr.hts.webos3.git
cd pvr.hts.webos3
./build.sh
```

Result:

```
dist/pvr.hts-webos-armv7.zip
```

The script is idempotent: the toolchain, the Kodi checkout, the dependency
prefix and every built library are reused on re-runs. `./build.sh --clean`
restarts from scratch.

### Options

| Variable | Default | Meaning |
|---|---|---|
| `JOBS` | CPU count | Parallel make jobs |
| `KODI_REF` | pinned master commit with `ADDON_API 22.90.701` | xbmc/xbmc branch, tag or commit to build against |
| `EXPECTED_ADDON_API` | `22.90.701` | Warns if the Kodi tree exposes a different API |
| `SDK_TAG` | `2026.08-webos` | openlgtv/buildroot-nc4 release |
| `SDK_ASSET` / `SDK_SHA256` / `SDK_URL` | defaults for x86_64 hosts | Toolchain download override |
| `ADDON` | `pvr.hts` | Any other binary add-on id (e.g. `inputstream.ffmpegdirect`) |
| `OUTPUT_NAME` | `pvr.hts-webos-armv7.zip` | Output file name |

Flags: `--no-deps` (skip apt), `--clean` (wipe `build/` and `dist/`), `--help`.

Examples:

```bash
# Track xbmc/xbmc master (only while master still reports ADDON_API 22.90.701)
KODI_REF=master ./build.sh

# Exact reproduction of the Kodi commit the add-on must match
KODI_REF=623f24ad8cf0c6ceb4a4eaeadc8fea7875239343 ./build.sh

# Build a different add-on with the same toolchain
ADDON=inputstream.ffmpegdirect OUTPUT_NAME=inputstream.ffmpegdirect-webos-armv7.zip ./build.sh
```

### Pinning the exact Kodi commit

The safest match is the exact git commit of the Kodi build installed on the TV.
Get it from Kodi's log (`~/.kodi/temp/kodi.log` on the TV, or
*Settings → System → Logging → View log*). The first lines look like:

```
Starting Kodi (23.0-ALPHA1 (22.90.701) Git:20261114-623f24ad8c). Platform: webOS ARM 32-bit
```

Then run:

```bash
KODI_REF=623f24ad8cf0c6ceb4a4eaeadc8fea7875239343 ./build.sh
```

`./build.sh` prints the API version stamped into the add-on, which must match
`22.90.701` (the `ADDON_API` your Kodi reports).

---

## GitHub Actions (cloud build)

The workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) runs the
same `./build.sh` on `ubuntu-latest`.

### Manual build

- GitHub UI: **Actions → build-pvr-hts-webos → Run workflow** (optionally set
  `kodi_ref` and `sdk_tag`).
- CLI:

  ```bash
  gh workflow run build.yml
  gh run watch
  gh run download --name pvr.hts-webos-armv7
  ```

The zip is attached to every run as the **`pvr.hts-webos-armv7`** artifact.

### Releases

Push a tag and the zip is attached to a GitHub Release automatically:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The webOS SDK is cached between runs (`build/toolchain`), so only the first run
performing a full dependency build is slow. The workflow also validates
`build.sh` with `shellcheck` and parses the workflow YAML before building.

---

## Install on the TV

You need [webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop)
(or any way to write files to the Kodi app directory — e.g. FileZilla over SSH
on a rooted TV).

1. Unzip `pvr.hts-webos-armv7.zip`. It contains a single folder `pvr.hts/`.
2. In **webOS Dev Manager**, connect to the TV, open the app file browser for
   `org.xbmc.kodi` and navigate to:

   ```
   /media/developer/apps/usr/palm/applications/org.xbmc.kodi/addons/
   ```

3. Upload the whole `pvr.hts/` folder into `addons/` (it must end up at
   `.../org.xbmc.kodi/addons/pvr.hts/`).
4. Restart Kodi. Enable the add-on from
   **Add-ons → My add-ons → PVR clients → Tvheadend HTSP Client**, then
   configure host/user/password under **Settings → PVR & Live TV**.

> Kodi on webOS normally cannot "Install from zip" binary add-ons because the
> add-ons directory belongs to the app package; copying the folder is the
> reliable method. webOS Dev Manager's file browser is the easiest way to do it.

### Compatibility notes

- Built for **webOS ARMv7** (the `-WEBOS-3-plus` / `arm` target of the official
  Kodi ipk), e.g. webOS 3.x–7.x TVs; it is the same target your
  `22.90.701` Kodi uses.
- The archive contains a real `pvr.hts.so` (not a symlink), so it survives
  uploads through webOS Dev Manager's file browser.
- Verified stamping: `kodi.binary.instance.pvr` minversion `9.2.0` — identical
  in every Kodi build that reports `ADDON_API 22.90.701`.
- Do not install it on Kodi **22.0 "Piers"** (version code `21.90.902`) or on
  ARM64 builds — those need a differently built add-on (`SDK_ASSET=...-aarch64`
  plus a matching `KODI_REF` branch).
- After updating Kodi, re-check `ADDON_API`; if it changed, rebuild with the new
  commit/API.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Kodi says the add-on is incompatible / dependency not met | The add-on was built against a different API. Read `ADDON_API` from your `kodi.log` and rebuild with `KODI_REF` = that build's git commit; keep `EXPECTED_ADDON_API` in sync. |
| Add-on fails to load with `GLIBC_2.xx not found` | Rebuild with the older SDK: `SDK_TAG=webos-b17b4cc ./build.sh --clean`. |
| `tools/depends` build fails in a library | Re-run `./build.sh` (it is incremental). If it keeps failing, clean just that library: `make -C build/xbmc/tools/depends/target/<lib> distclean` and re-run. |
| CI runs out of disk | Unlikely thanks to the free-space step; if it happens, remove the tarball cache from the repository's Actions cache page. |
| `Could not locate the toolchain` | The SDK asset does not match your host arch; set `SDK_ASSET` (use `...-aarch64.tar.gz` on ARM hosts) or `SDK_URL`. |

---

## Repository layout

```
build.sh                     idempotent cross-build script
.github/workflows/build.yml  GitHub Actions CI (artifact + release)
.gitignore                   ignores build/, dist/, downloads
README.md                    this file
```

## Credits

- [Kodi](https://github.com/xbmc/xbmc) — build system and
  [`docs/README.webOS.md`](https://github.com/xbmc/xbmc/blob/master/docs/README.webOS.md)
- [pvr.hts](https://github.com/kodi-pvr/pvr.hts) — the add-on itself (GPL-2.0-or-later)
- [openlgtv/buildroot-nc4](https://github.com/openlgtv/buildroot-nc4) — webOS toolchain
- [webosbrew](https://github.com/webosbrew) — webOS developer tooling

This repository only contains build automation; the built add-on is subject to
the pvr.hts license (GPL-2.0-or-later).
