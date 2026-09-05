# Installing the AArch64 CANN toolkit on the build host

Stage 0 of `docker/target-310p/Dockerfile.aarch64` installs the aarch64 CANN toolkit on the build
host's own architecture and the arm64 stage `COPY --from`s the finished tree.
This is the single largest build-time saving in the repo. Here is why it is
safe, and how it was verified.

## Why

Measured on this build host (WSL2, x86_64, 12 cores), CANN 8.5.0:

| | Emulated (qemu-aarch64) | Native x86_64 |
|---|---:|---:|
| outer package self-extract | 61 s | 14 s |
| 21 component packages self-extract | 100 s | 24 s |
| install scripts (merge, symlinks, `--pylocal`) | ~456 s | ~50 s |
| **whole step** | **617 s** | **88.5 s** |

Decompression is only about a quarter of it. The bulk is the installer itself:
pure shell that spawns thousands of `cp`/`ln`/`chmod`/`mkdir` processes, each
paying the qemu-user process-startup tax. Nothing in that work is
architecture-specific — it copies aarch64 payload files into place, driven by a
`filelist.csv` per component (4060 rows of `mkdir`/`copy`/`del`/`copy_entity`)
and creates symlinks.

Together with the `COPY --from`, which BuildKit performs on the host in 4.9 s
rather than under emulation, CANN handling drops from **617 s to ~93 s**.

## How

The only thing tying the installer to aarch64 is *which* component packages it
selects, which it reads from the `arch` command:

```
[Toolkit] [INFO] The current OS is x86_64
[Toolkit] [ERROR] No packages to install !
```

So stage 0 puts a two-line `arch` (and `uname -m`) shim on `PATH` that names the
target architecture, and then runs the **vendor installer, unmodified**:

```
bash /tmp/cann.run --full --quiet --install-path=/usr/local/Ascend --install-for-all
```

Using the real installer rather than replaying `filelist.csv` by hand is the
point: the merge, the permissions, the `latest` → `cann` → `cann-8.5.0` symlink
chain and every `--pylocal` step are all done by the code that owns them.

The stage's base image must already carry `python3` and `pip3`, which several
components invoke through `--pylocal`; that is why it is `python:3.10-slim` and
not `ubuntu:22.04`. It needs no network — the build still runs `--network=none`.

If the build host is itself aarch64 the shim is a no-op and stage 0 is an
ordinary native install.

## Verification

The natively-installed tree was diffed against the emulated one inside the
previous known-good image, over `cann-8.5.0`:

| Check | Result |
|---|---|
| files / symlinks / dirs | 19144 / 620 / 2761 — same as emulated |
| paths present only in the native tree | **0** |
| paths present only in the emulated tree | 29, **all accounted for** |
| symlink target differences | **0** |
| type or mode differences | 126, **all accounted for** |

The 29 extra paths in the emulated tree are not installer output: 21 are the
libraries stage 3b copies in from `deps/cann_extra` (`libhccl.so`,
`libopapi.so`, the `libacl_dvpp*` set …) and 8 are `__pycache__/*.pyc` written
at runtime. The 126 mode differences are all `lib64/*.so` at `755` instead of
`444`, which is stage 3b's own `chmod 0755 "$lib"/*.so*` applied to the whole
directory. Both post-install steps still run, unchanged, after the `COPY`.

Reproduce the comparison by generating a manifest on each side:

```bash
cd /usr/local/Ascend/cann-8.5.0 && find . -printf '%y %m %s %p\n' | sort
cd /usr/local/Ascend/cann-8.5.0 && find . -type l -printf '%p -> %l\n' | sort
```

The image is then built and `verify_runtime.sh` run against it as usual; a
correct CANN tree is a precondition for `import torch_npu` and for the
vllm-ascend wheel build, both of which happen downstream of this stage.

## Falling back

If a future CANN release changes the installer such that the host-side path
misbehaves, the emulated install is a two-line revert: drop the
`cann-unpacker` stage and restore the original step in the arm64 lineage,

```dockerfile
RUN --mount=type=bind,source=deps/Ascend-cann-toolkit_${CANN_VERSION}_linux-aarch64.run,target=/tmp/cann-aarch64.run \
    bash /tmp/cann-aarch64.run --full --quiet --install-path=${ASCEND_BASE} --install-for-all
```

in place of `COPY --from=cann-unpacker`. Everything downstream is unchanged.
Re-run the manifest comparison above before trusting a new toolkit version.
