**NOTE:** This is AI generated code. There is nothing really critical going on, but you might still want to take a look at the short script to make sure what's going on at least at a high level.
It worked just fine on my Ubuntu 24.04 machine with Hyprland v0.39.1.

# Omasnap Docker (distrobox) installer

Installer for [omasnap](https://github.com/tobi/omasnap) for Ubuntu and other
Linux distributions that are not Arch Linux.

The tool will run in a container and the command can be used with the same hyprland shortcut.

Omasnap's dependencies are Arch-oriented (`hyprland`, `layer-shell-qt`, and other
`pacman` packages), so this script never touches your distro's own package manager.
Instead it:

1. Creates an **Arch Linux container** with `distrobox` (backed by Docker).
2. Installs the Arch dependencies and builds omasnap **inside that container**.
3. Installs a small **host launcher** (`~/.local/bin/omasnap`) that runs the
   containerized binary from your Hyprland session.

On Ubuntu or any other non-Arch distro, you only need the three prerequisites below;
all Arch packages, build tools, and the omasnap binary itself are handled inside the
container.

## Requirements

1. **A running Wayland + Hyprland session**

   omasnap is Wayland-native and uses `hyprctl` IPC. The script warns if
   `WAYLAND_DISPLAY` or `HYPRLAND_INSTANCE_SIGNATURE` are unset.

2. **Core host CLI tools**

   `git` and `curl` (to fetch distrobox and clone the source), plus `grim`,
   `wl-copy`, and `wl-paste` for capture and clipboard. On Ubuntu:

   ```bash
   sudo apt install git curl grim wl-clipboard
   ```

3. **Docker, running and usable by the current user**

   The daemon must be up and your user must be able to run Docker (e.g. be in the
   `docker` group). The script refuses to run as root. On Ubuntu:

   ```bash
   sudo apt install docker.io
   sudo usermod -aG docker "$USER"   # log out and back in afterwards
   sudo systemctl enable --now docker
   ```

## Install

```bash
git clone https://github.com/tobi/omasnap.git
cd omasnap-docker
./install.sh
```

The script installs distrobox into `~/.local`, builds omasnap inside the
`omasnap-arch` container, and installs the launcher at `~/.local/bin/omasnap`.
Ensure `~/.local/bin` is on your `PATH`.

## Usage

```bash
omasnap --help
omasnap                    # region capture
omasnap --capture-fullscreen --save
```

Suggested Hyprland binding:

```
bind = $mainMod SHIFT, S, exec, ~/.local/bin/omasnap
```

## Notes

- The first launch after a reboot may have a short container startup delay.
- Re-run `install.sh` to update and rebuild omasnap.
- Only Docker is required on the host; no Arch packages are installed on it.
