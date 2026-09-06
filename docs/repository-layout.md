# Repository layout — what belongs where, and what must never be committed

This repository builds **offline** Ascend inference images: every image is
assembled with `--network=none`, from a payload staged beforehand. That split —
*provisioned bytes* on one side, *committed sources* on the other — is what the
directory layout encodes, and it is why the rules below are enforced by
`.gitignore` and `.dockerignore` rather than left to habit.

The canonical tree:

```
<project_root>/                      on the Windows workspace drive
├── artifacts/                       final deployable archives      [GIT-IGNORED]
├── deps/<target>/                   offline staging payload        [GIT-IGNORED]
├── targets/<target>/                self-contained target scaffold [COMMITTED]
├── builders/<builder>/              host-side toolchain images     [COMMITTED]
├── common/                          logic shared by every target   [COMMITTED]
├── docs/                            design notes and build records [COMMITTED]
└── download_deps.sh                 shared integrity-checked fetch [COMMITTED]
```

Each target owns the same four entry points, so a target is driven the same way
whatever its architecture:

| Entry point | Runs where | Network |
|---|---|---|
| `targets/<target>/provision.sh` | host, plus throwaway containers | yes - the only step that uses it |
| `targets/<target>/build.sh` | host | no, `--network=none` |
| `targets/<target>/run_dev.sh` | host | no by default |
| `targets/<target>/verify_runtime.sh` | inside the image, as `docker run <image> verify` | no |

---

## `artifacts/` — final deployable release archives

**Committed: never. Location: the Windows workspace filesystem.**

Holds only *finished, deployable* output: exported images
(`docker save | pigz` → `.tar.gz`) and wheelhouse bundles meant to be copied to
a target host. Nothing here is an input to a build, and nothing here is
intermediate.

It lives on the **Windows drive**, not inside the WSL filesystem, so that
archives survive `wsl --shutdown`, a distro reset or a `docker system prune`,
and are reachable from Explorer and Windows tooling. When a build script writes
here from WSL, it writes through `/mnt/<drive>/...`:

```
/mnt/d/Projects/docker-cann-cross-compile-toolkit-aarch64/artifacts/
```

Two rules follow, and both are mechanically enforced:

* **Never tracked by git.** `.gitignore` carries both `artifacts/` and
  `*.tar.gz`; the archives are multi-GB and regenerated on demand.
* **Never pulled into a Docker build context.** `.dockerignore` excludes
  everything by default (`*`) and re-includes only `deps`, `targets`, `builders` and `common`, so
  `artifacts/` cannot reach BuildKit. This matters more than it looks: the
  context for these images is the repository root, and a stray 3 GB archive
  would be hashed and transferred on every single build.

**Cross-filesystem integrity.** Copying from WSL's ext4 to `/mnt/d` crosses a
9p/drvfs boundary. Always verify the SHA-256 *on the destination* after the
copy, and prefer `cp` + verify + `rm` over `mv`: a cross-filesystem `mv` is a
copy-then-delete internally, so an interruption can leave you with neither copy
of something that took an hour and a half to build.

## `deps/<target>/` — offline staging area

**Committed: never.** Everything under `deps/` is produced by
`targets/<target>/provision.sh`, which is the *only* step in this repository that
uses the network. It holds the CANN `.run` installers, the vendor `cann_extra`
libraries, the local apt archive, the wheelhouse, third-party ACLNN archives and
the plugin source checkouts.

Partitioned per target (`deps/950pr-x86_64/`, and the 310P payload) because two
targets have different architectures, CANN versions and interpreter versions,
and a shared directory silently mixes them.

Each target's contents are declared in `targets/<target>/deps.manifest`, and the
build script refuses to start until every row is satisfied — so the payload is
*checked*, not assumed. `deps/` stays on the WSL filesystem: it is read
constantly during a build, and drvfs would make that slow.

## `targets/<target>/` — self-contained target scaffolds

**Committed: entirely.** One directory per target, holding everything that
defines the image and nothing that is downloaded:

```
targets/target-950pr/
├── Dockerfile.x86_64          the image itself
├── build.sh                   builds it, --network=none
├── provision.sh               stages deps/<target>/, the only networked step
├── run_dev.sh                 interactive shell in the built image
├── entrypoint.sh              runtime entry point
├── verify_runtime.sh          the check suite baked into the image
├── constraints.x86_64.txt     pip constraints (keeps CUDA wheels out)
├── deps.manifest              what deps/<target>/ must contain
├── packages/                  apt package list
└── requirements/              the wheelhouse specification
```

The test is: **deleting `deps/` must never lose anything that is not
re-downloadable from this directory's declarations.**

## `common/` — one implementation per problem, not one per target

**Committed: entirely.** Both targets differ in architecture, CANN version and
interpreter, but hit the same host defects and the same vendor omissions. What
is genuinely shared lives here and is parameterised by environment, never
forked:

```
common/
├── scripts/
│   ├── fetch.sh                 resumable single-stream and chunked-range fetch
│   ├── container_prelude.sh      IPv4 preference, qemu ldconfig stub, offline apt
│   ├── fetch_debs.sh             local apt archive from a target package list
│   ├── fetch_wheels.sh           three-pass wheelhouse resolver with the CUDA gate
│   ├── build_vllm_wheel.sh       vLLM built with VLLM_TARGET_DEVICE=empty
│   └── run_dev.sh                dev-shell launcher behind each run_dev.sh
├── docker/
│   ├── base.Dockerfile           reusable base stage, opt-in via BASE_IMAGE
│   ├── compiler_env.sh           Ascend C build environment for dev shells
│   └── driver_plumbing.sh        HwHiAiUser accounts and driver directories
└── patches/
    ├── ascend_setenv_nounset.sh  vendor set_env.sh is not nounset-clean
    ├── hccl_devlib_fallback.sh   libhccl.so is absent from the toolkit package
    └── cmake_fetchcontent_local.sh  offline overrides for the ACLNN CMake fetches
```

`common/scripts` is mounted at `/common` inside provisioning containers;
`common/docker` and `common/patches` are bind-mounted or COPYed by the target
Dockerfiles. Everything under `common/` must therefore stay inside the build
context - `.dockerignore` re-includes it explicitly.

CONSTRAINT - `common/patches/cmake_fetchcontent_local.sh` is NOT called from the
RUN that compiles the ACLNN kernels. BuildKit keys a layer on the literal
command string plus its mounts, so referencing it there would invalidate a
~90-minute compile. That logic is inlined in both Dockerfiles and kept in step
by hand; the file is what run_dev.sh and any out-of-image build use.

## `csrc/` and `src/` — plugin source trees

Source only. Build output — `build/`, `dist/`, `*.egg-info`, `_version.py`,
`_build_info.py`, `.deps/`, compiled `*.so` — must never be committed, and the
Dockerfiles are written so it never needs to be: the vllm-ascend checkout is
copied *out* of its read-only bind mount before `setup.py` runs, precisely
because the build writes those files back into the tree.

In this repository these trees arrive under `deps/<target>/src/` as provisioned
sources rather than as committed code, so they are ignored wholesale. The rule
still matters for anyone vendoring a plugin directly into the repository.

---

## Enforcement

| Rule | Enforced by |
|---|---|
| `artifacts/` never tracked | `.gitignore`: `artifacts/`, `*.tar.gz` |
| `artifacts/` never in a build context | `.dockerignore`: `*` then `!deps`, `!targets`, `!builders`, `!common` |
| `deps/` never tracked | `.gitignore`: `deps/` |
| Build output never tracked | `.gitignore`: `build/`, `dist/`, `*.egg-info/`, `*.so` |
| Payload completeness | `deps.manifest` + build-script preflight |
| No CUDA in an Ascend payload | `constraints.x86_64.txt`, wheelhouse gate, preflight gate, in-image assertion |

Check the enforcement rather than trusting it:

```bash
git check-ignore -v artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
git status --short          # must never list artifacts/ or deps/
```
