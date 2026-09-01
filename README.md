# agents-devbox

A self-contained **AI coding sandbox** in a container: Claude Code, OpenAI Codex,
Cursor and xAI Grok pre-installed, wired for isolated, permission-bypassed use
(the container *is* the sandbox), with a zsh setup and persistent per-user config.

All egress leaves through a VPN of your choice, and the container re-exports it
as a SOCKS5 proxy for apps on the host.

Base: Ubuntu 24.04 · JDK 17 · Node 22 · Python 3 · timezone Europe/Moscow.

---

## AI agents included

| Command  | Tool             | Notes                                            |
|----------|------------------|--------------------------------------------------|
| `claude` | Claude Code      | aliased with `--dangerously-skip-permissions`    |
| `codex`  | OpenAI Codex CLI | aliased with `--dangerously-bypass-approvals-and-sandbox` |
| `cursor` | Cursor agent     | aliased with `--yolo` (a.k.a. `cursor-agent`)    |
| `grok`   | xAI Grok CLI     | aliased with `--permission-mode bypassPermissions`; run `grok login` first |

> Bypass flags are safe here because the whole container is an isolated,
> disposable environment. Do **not** replicate these aliases on a host machine.

## What's inside

- **Shell:** zsh + oh-my-zsh, Powerlevel10k prompt (ASCII mode, no Nerd Font
  required), `zsh-autosuggestions` (history) and `zsh-syntax-highlighting`.
- **Tooling:** git, `gh`, build-essential, python3/venv, plus the usual network
  diagnostics (dig, tcpdump, nmap, socat, mtr, …).
- **Networking:** three selectable egress modes (see below) and a SOCKS5 proxy
  (danted) on `127.0.0.1:<port>` to tunnel host apps through the same VPN.
- **Android:** `ANDROID_HOME`/SDK bind-mounted from the host; the host SDK path is
  symlinked inside the container, so a `local.properties` shared with the host
  resolves on both sides.
- **Gradle:** the container keeps its **own** Gradle home in the volume and reads
  the host's dependency cache read-only — sharing one Gradle home across the
  macOS/Linux boundary corrupts Gradle's caches.
- **Persistence:** a named volume `devbox` keeps agent configs/sessions
  (`~/.claude`, `~/.codex`, `~/.cursor`, `~/.grok`), your shell configs
  (`~/.zshrc`, `~/.p10k.zsh`, history, …), the Gradle home and sing-box state
  across container recreation. On first start the image defaults are seeded into
  the volume, then symlinked back into `$HOME`, so your edits survive rebuilds.

---

## Quick start (docker compose)

`docker-compose.yml`:

```yaml
services:
  devbox:
    image: craft4ik/agents-devbox:latest
    container_name: devbox
    hostname: devbox
    user: ${DEV_USER}
    environment:
      TZ: Europe/Moscow
      VPN_MODE: ${VPN_MODE}
      HOST_ANDROID_SDK: ${HOST_ANDROID_SDK}
      SUB_URL: ${SUB_URL:-}
      HOSTPROXY_HOST: ${HOSTPROXY_HOST:-}
      HOSTPROXY_PORT: ${HOSTPROXY_PORT:-}
      HOSTPROXY_DNS_SERVER: ${HOSTPROXY_DNS_SERVER:-}
      HOST_JAVA_CACERTS_PASS: ${HOST_JAVA_CACERTS_PASS:-}
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    sysctls:
      net.ipv4.conf.all.src_valid_mark: 1
    ports:
      - "127.0.0.1:${SOCKS_PUBLISH_PORT}:1080"
    volumes:
      - "./wireguard/:/etc/wireguard/:ro"
      - "${HOST_ANDROID_SDK}:/home/${DEV_USER}/Android/Sdk"
      - "${HOST_WORK_DIR}:/home/${DEV_USER}/mnt/.work"
      # Same tree at its host path too, so Gradle's caches survive host<->container switches.
      - "${HOST_WORK_DIR}:${HOST_WORK_DIR}"
      - "${HOST_GIT_CONFIG}:/home/${DEV_USER}/.gitconfig:ro"
      - "${HOST_SSH_DIR}:/home/${DEV_USER}/.ssh:ro"
      - "${HOST_GRADLE_HOME}/caches:/var/lib/devbox/gradle/caches-ro:ro"
      # Optional custom CA truststore; unset -> /dev/null, which the entrypoint skips.
      - "${HOST_JAVA_CACERTS:-/dev/null}:/etc/devbox/custom-cacerts:ro"
      - "devbox:/var/lib/devbox"
    working_dir: /home/${DEV_USER}/mnt/.work
    restart: unless-stopped
    tty: true
    stdin_open: true
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  devbox:
```

Start and enter:

```bash
docker compose up -d
docker exec -it -u corp devbox zsh
```

The published image ships the user `corp` (`1000:1000`), baked in at build time —
keep `DEV_USER=corp` unless you rebuild the image yourself.

---

## Configuration (`.env`)

Create a `.env` next to the compose file:

```dotenv
# Username/UID inside the container. Must match the user baked into the image
# (corp / 1000 / 1000) unless you rebuild it yourself.
DEV_USER=corp
DEV_UID=1000
DEV_GID=1000

# Host paths to bind-mount into the container (use forward slashes on Windows).
HOST_ANDROID_SDK=/absolute/path/to/AndroidSDK
HOST_WORK_DIR=/absolute/path/to/workdir
HOST_GIT_CONFIG=/absolute/path/to/.gitconfig
HOST_SSH_DIR=/absolute/path/to/.ssh

# Host Gradle home. Its dependency cache is mounted read-only; the container
# writes to its own Gradle home in the volume.
HOST_GRADLE_HOME=/absolute/path/to/.gradle

# Optional: a custom Java truststore (JKS/PKCS12) with your corporate CAs. On
# start its certs are merged into the container JDK's cacerts, so TLS to
# internal hosts (e.g. the Gradle artifact repo) is trusted. Leave empty to
# skip; the password defaults to changeit.
HOST_JAVA_CACERTS=
HOST_JAVA_CACERTS_PASS=

# Egress mode (REQUIRED). One of: singbox | hostproxy | wireguard
VPN_MODE=singbox

# singbox mode: subscription URL whose panel returns sing-box JSON.
SUB_URL=

# hostproxy mode: where the upstream SOCKS5 proxy lives. Empty = the Docker host
# (host.docker.internal); set a LAN/router IP to dial that instead.
HOSTPROXY_HOST=
# hostproxy mode: port of the upstream SOCKS5 proxy (on HOSTPROXY_HOST).
# Distinct from SOCKS_PUBLISH_PORT below.
HOSTPROXY_PORT=
# hostproxy mode: resolver reached through that proxy (default 8.8.8.8).
HOSTPROXY_DNS_SERVER=

# wireguard mode: put your config(s) in ./wireguard/*.conf next to the compose
# file. The filename minus .conf becomes the interface name.

# Host port for the SOCKS5 proxy (bound to 127.0.0.1 only).
# danted always listens on 1080 inside the container.
SOCKS_PUBLISH_PORT=1080
```

| Variable               | Purpose                                                          |
|------------------------|------------------------------------------------------------------|
| `DEV_USER/UID/GID`     | In-container user; must match the image's baked-in user          |
| `HOST_ANDROID_SDK`     | Android SDK bind-mounted to `~/Android/Sdk`                      |
| `HOST_WORK_DIR`        | Your projects dir, mounted to `~/mnt/.work` (working dir)        |
| `HOST_GIT_CONFIG`      | `~/.gitconfig` (read-only) from the host                         |
| `HOST_SSH_DIR`         | `~/.ssh` (read-only) from the host                               |
| `HOST_GRADLE_HOME`     | Host Gradle home; its dependency cache is mounted read-only      |
| `HOST_JAVA_CACERTS`    | Optional CA truststore merged into the JDK cacerts on start      |
| `HOST_JAVA_CACERTS_PASS` | Password for `HOST_JAVA_CACERTS` (default `changeit`)          |
| `VPN_MODE`             | **Required.** `singbox` \| `hostproxy` \| `wireguard`            |
| `SUB_URL`              | `singbox` mode: subscription URL returning sing-box JSON         |
| `HOSTPROXY_HOST`       | `hostproxy` mode: upstream proxy host; empty = the Docker host   |
| `HOSTPROXY_PORT`       | `hostproxy` mode: port of the upstream SOCKS5 proxy              |
| `HOSTPROXY_DNS_SERVER` | `hostproxy` mode: resolver behind that proxy (default `8.8.8.8`) |
| `SOCKS_PUBLISH_PORT`   | Host port for the SOCKS5 proxy (`127.0.0.1:<port>` → `:1080`)    |

---

## Egress modes

`VPN_MODE` is required and selects how traffic leaves the container. The
resulting interface is what the SOCKS5 proxy re-exports to the host.

| `VPN_MODE`  | How it works                                                       | Needs                              |
|-------------|--------------------------------------------------------------------|------------------------------------|
| `singbox`   | sing-box TUN from a VLESS+Reality subscription (Remnawave panel)   | `SUB_URL`                          |
| `hostproxy` | sing-box TUN forwarding everything into a SOCKS5 proxy on the host | `HOSTPROXY_PORT`                   |
| `wireguard` | brings up every `./wireguard/*.conf`                               | config file(s) in `./wireguard/`   |

For both sing-box modes, `/etc/resolv.conf` is repointed at `1.1.1.1`/`8.8.8.8`,
since Docker's default resolver sits on loopback and would bypass the TUN. The
host gateway and `192.168.0.0/16` are kept out of the tunnel, so host-bound
traffic (the published proxy, MCP servers on the host) reaches the host directly
instead of looping back through the proxy.

In `singbox` mode the subscription JSON is validated and cached in the volume, so
later starts still work when the panel is unreachable. In `wireguard` mode the
filename minus `.conf` becomes the interface name (letters, digits, `-`, `_`;
15 chars max).

---

## Notes

- Requires `NET_ADMIN`, `/dev/net/tun` and the `src_valid_mark` sysctl.
- First launch takes a moment to seed configs into the volume.
- Tunnel host apps through the VPN via the SOCKS5 proxy at
  `127.0.0.1:${SOCKS_PUBLISH_PORT}`.
- `HOST_JAVA_CACERTS` is merged into the JDK truststore at **runtime**, so your
  corporate CAs are never baked into the image; cert rotation needs no rebuild.
- Project-local `.gradle/` and `build/` are shared with the host, so build from
  one side at a time.
- sing-box logs land in `/var/lib/devbox/singbox/sing-box.log`.
- `docker volume rm devbox` wipes agent sessions, shell history *and* the
  container's Gradle home.
