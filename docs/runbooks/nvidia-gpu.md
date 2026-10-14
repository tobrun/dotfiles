# Runbook: NVIDIA driver + CUDA (login-loop recovery)

Host-only layer. Declared in `packages/apt/nvidia.txt` (repo bound via
`packages/apt/repos/nvidia.*`); converged by `modules/apt.sh nvidia` as root.
This runbook records the 2026-10 incident that made the declaration, the
canonical recovery, and the acceptance checks.

## The incident (2026-10)

Two driver sources were mixed on this machine: Ubuntu-archive driver packages
(`nvidia-driver-595-open` family) coexisting with CUDA-repo pieces. The DKMS
module and the userspace libraries ended up from different builds, the kernel
module failed to load, and X/Wayland fell back and over into a **graphical
login loop**. Also learned the hard way: do not pin a CUDA toolkit version
like `cuda-toolkit-13-0` — it freezes you on CUDA 13.0 while the driver
line moves on; declare the floating `cuda-toolkit` metapackage instead.

## The rule

**One driver source: NVIDIA's CUDA repository, always.** Never install
Ubuntu-archive `nvidia-*` driver packages on this machine. Corollaries:

- Driver = `nvidia-open` (NVIDIA repo). It `Breaks`/`Replaces`
  `cuda-drivers`, so NVIDIA's own `cuda-drivers` metapackage stays
  uninstalled too; the toolkit comes from `cuda-toolkit` alone.
- After any `apt full-upgrade`, re-check that nothing archive-origin got in:
  `apt list --installed | grep -i nvidia` → NVIDIA-repo packages only.
- `scripts/drift.sh` proves the declared packages are present; this grep is
  the manual half that proves nothing *undeclared* crept in.

## Recovery from a mixed-source login loop

1. **Text console**: Ctrl+Alt+F3, log in. Check Secure Boot:
   `mokutil --sb-state`. If *enabled*, the DKMS step will enroll a MOK and
   ask for a one-time password; after reboot, choose "Enroll MOK" on the
   blue shim screen — skipping it re-loops the login. (This host: Secure Boot
   **disabled**, no MOK dance needed.)

2. **Purge every NVIDIA/CUDA package, from whichever source**:
   ```bash
   sudo apt purge '*nvidia*' '*cuda*' 'libnvidia*'
   sudo apt autoremove --purge
   sudo reboot
   ```
   Login now works on nouveau — proof the driver was the fault.

3. **Re-converge from the declaration** (repo keyring + sources + packages
   in one pass; no manual keyring dearmor, no vendor cuda-keyring deb):
   ```bash
   cd ~/ws/dotfiles
   sudo bash modules/apt.sh nvidia
   sudo reboot
   ```
   If apt reports dependency conflicts, stop and capture the error — the
   known-good shape is `nvidia-open` + `cuda-toolkit`, nothing else.

## Verification (acceptance)

```bash
nvidia-smi                      # driver answers, GPU listed
dkms status                     # nvidia/open module installed+built
nvcc --version                  # toolkit (current line: CUDA 13.4)
apt list --installed | grep -i nvidia   # NVIDIA-repo origin only
bash modules/apt.sh --check nvidia      # declaration converged
```

`~/.bashrc` PATH/LD_LIBRARY_PATH for `/usr/local/cuda` is owned by chezmoi
(`home/dot_bashrc`, guarded so it is inert before the toolkit exists) —
never hand-append exports to `~/.bashrc`.

## Facts at declaration time (2026-10-14)

- Ubuntu 26.04.1, kernel 7.0.0-38-generic, Secure Boot disabled.
- NVIDIA repo publishes an `ubuntu2604` directory; CUDA 13.4 is the current
  toolkit line (validated for 26.04.1 per NVIDIA's 13.4 guide, Sep 2026).
- Repo candidates at declaration: `nvidia-open 615.x`, `cuda-toolkit 13.4.3`.
- Signing key `14BAFBC7562AD710CA04E69905FBB6DA60DF8A40` (Kitmaker/
  Ubuntu-26.04, NVIDIA's per-release signing key) — pinned in
  `packages/apt/repos/nvidia.key.asc`, verified against the repo InRelease.
