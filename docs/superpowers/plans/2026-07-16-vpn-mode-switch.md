# Devbox VPN Mode Switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the devbox container's egress strategy selectable at launch via `VPN_MODE`, adding a sing-box TUN path (fed by a Remnawave VLESS+Reality subscription) and a host-SOCKS5 path alongside the existing WireGuard path.

**Architecture:** A rewritten `entrypoint.sh` keeps its persist-config block verbatim, then dispatches on `VPN_MODE` to one of three mode scripts under `docker-build/net/`. `singbox` and `hostproxy` share one TUN engine (sing-box); they differ only by outbound. `wireguard` is the current logic lifted verbatim plus a fail-fast guard. danted runs in all modes with its `external:` interface rendered per mode. Design spec: `docs/superpowers/specs/2026-07-16-vpn-mode-switch-design.md`.

**Tech Stack:** Bash, Docker/Docker-Compose, sing-box v1.13.14 (Go TUN proxy), dante-server (SOCKS5), nftables, jq 1.7, curl.

## Global Constraints

- **sing-box pinned to `v1.13.14`.** Install from the official GitHub release tarball `sing-box-1.13.14-linux-${ARCH}.tar.gz` (ARCH ∈ {`amd64`,`arm64`} from `dpkg --print-architecture`), verified against its published SHA256, binary extracted to `/usr/local/bin/sing-box`.
- **`VPN_MODE` is required.** Empty or unrecognised → entrypoint exits non-zero with a message listing valid modes (`singbox`|`hostproxy`|`wireguard`). No default.
- **No `--privileged`, no `SYS_MODULE`.** Only additions: `devices: [/dev/net/tun]`; `NET_ADMIN` and `src_valid_mark` sysctl are already present.
- **Robustness over cleverness.** No coupling to the panel's tags/servers/keys. The panel sing-box JSON is patched only structurally (by `type`), never by tag/emoji/server.
- **Minimal intervention in existing code.** The persist-config block of `entrypoint.sh`, the WireGuard `wg-quick` loop, and the body of `danted.conf` are preserved byte-for-byte except where a task explicitly changes them.
- **Secrets never logged.** uuid, reality keys, subscription token must never be printed.
- **Non-root at runtime.** Container runs as `${DEV_USER}`; privileged operations (writing `/etc/resolv.conf`, `wg-quick`, `danted`, `nft`, `ip`) use `sudo`, matching the existing entrypoint convention.
- **Subscription UA:** `SFA/1.11 (io.nekohasekai.sfa) sing-box` (only this UA yields JSON; a bare `sing-box` UA yields base64 and must be rejected).

---

## File Structure

```
docker-build/
  entrypoint.sh              # MODIFY: keep persist block; add VPN_MODE dispatch + danted render/start
  Dockerfile                # MODIFY: install sing-box v1.13.14 + nftables; COPY net/ scripts
  danted.conf               # DELETE (replaced by template)
  danted.conf.tmpl          # CREATE: danted.conf with __EXTERNAL_IFACE__ placeholder
  net/
    common.sh               # CREATE: shared helpers (log, die, wait_for_tun_ip, set_resolver, nft_preflight)
    fetch-subscription.sh   # CREATE: UA fetch + format guard + cache to volume
    mode-singbox.sh         # CREATE: preflight, fetch, jq-patch, check, start sing-box, wait TUN
    mode-hostproxy.sh       # CREATE: preflight, render base config, start sing-box, wait TUN
    mode-wireguard.sh       # CREATE: existing wg-quick loop lifted + fail-fast guard
    singbox-base.json       # CREATE: image-owned headless base config (TUN inbound + route + dns)
docker-compose.yml          # MODIFY: env vars, /dev/net/tun, wireguard/ dir mount, drop dns:
.env.example                # MODIFY: VPN_MODE, SUB_URL, HOST_SOCKS_PORT, WG migration note
wireguard/                  # CREATE dir: holds wg-*.conf (migration target)
```

Verification for infra work is behavioral, not unit-test-based: JSON validity (`jq`/`sing-box check`), shell syntax (`bash -n`), image build, and runtime container behavior. Each task ends with a concrete check and a commit.

---

### Task 0: Initialize version control (optional baseline)

The devbox directory is not under git. Frequent commits require it. This task snapshots the current working image before any change. Skip only if the user declined versioning.

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Init repo**

Run:
```bash
cd /home/corp/mnt/.work/docker/devbox
git init
```
Expected: `Initialized empty Git repository`

- [ ] **Step 2: Add a .gitignore for secrets and cruft**

Create `.gitignore`:
```
.env
.DS_Store
wireguard/*.conf
*.cache.json
```

- [ ] **Step 3: Commit the current state as baseline**

Run:
```bash
git add -A
git commit -m "chore: baseline devbox image before VPN mode switch"
```
Expected: a commit is created listing the existing files (`.env` and `wireguard/*.conf` excluded).

---

### Task 1: Add sing-box + nftables to the image

Install the pinned sing-box binary and the `nft` tool. No behavior change yet — just that `sing-box version` and `nft --version` work in the built image.

**Files:**
- Modify: `docker-build/Dockerfile` (the first `apt-get install` block, ~lines 14-27, and add a new sing-box install layer)

**Interfaces:**
- Produces: `/usr/local/bin/sing-box` (executable), `nft` on PATH.

- [ ] **Step 1: Look up the real SHA256 checksums for v1.13.14**

Run:
```bash
for a in amd64 arm64; do
  echo -n "$a: "
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box-1.13.14-linux-$a.tar.gz.sha256" 2>/dev/null || \
  curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.13.14" | jq -r ".assets[] | select(.name==\"sing-box-1.13.14-linux-$a.tar.gz\") | .browser_download_url"
done
```
Record the two checksums. If no `.sha256` asset exists, download each tarball and compute `sha256sum` locally; hardcode the results in Step 2.

- [ ] **Step 2: Add `nftables` to the apt install list**

In `docker-build/Dockerfile`, add `nftables` to the first `apt-get install -y --no-install-recommends` package list (the block starting `wireguard-tools iproute2 iptables dante-server`):
```
        wireguard-tools iproute2 iptables nftables dante-server \
```

- [ ] **Step 3: Add a pinned sing-box install layer**

After the nodejs layer (before the user-creation `RUN`), add (replace `<SHA_AMD64>` / `<SHA_ARM64>` with the values from Step 1):
```dockerfile
# sing-box (pinned) — TUN engine for the singbox/hostproxy VPN modes.
ARG SINGBOX_VERSION=1.13.14
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="<SHA_AMD64>";; \
      arm64) sha="<SHA_ARM64>";; \
      *) echo "unsupported arch: $arch" >&2; exit 1;; \
    esac; \
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/sb.tgz; \
    echo "${sha}  /tmp/sb.tgz" | sha256sum -c -; \
    tar -xzf /tmp/sb.tgz -C /tmp; \
    install -m 0755 "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}/sing-box" /usr/local/bin/sing-box; \
    rm -rf /tmp/sb.tgz "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}"; \
    /usr/local/bin/sing-box version
```

- [ ] **Step 4: Build and verify the tools exist**

Run:
```bash
cd /home/corp/mnt/.work/docker/devbox
docker compose build devbox 2>&1 | tail -20
docker compose run --rm --entrypoint sh devbox -c "sing-box version && nft --version"
```
Expected: build succeeds; prints a sing-box version line containing `1.13.14` and an `nftables vX.Y.Z` line. (The `sha256sum -c` step fails the build loudly if a checksum is wrong.)

- [ ] **Step 5: Commit**

```bash
git add docker-build/Dockerfile
git commit -m "feat: install pinned sing-box v1.13.14 and nftables in image"
```

---

### Task 2: Shared helpers (`net/common.sh`)

The primitives every mode uses. Pure functions + a few sudo-backed actions. Sourced by the mode scripts and the entrypoint.

**Files:**
- Create: `docker-build/net/common.sh`

**Interfaces:**
- Produces (sourced functions):
  - `log <msg>` / `die <msg>` — stderr logging; `die` exits 1.
  - `nft_preflight` — probes nftables writes; `die`s with a specific diagnostic on failure.
  - `set_resolver` — writes a non-loopback resolver into `/etc/resolv.conf` via sudo.
  - `snapshot_tuns` — echoes the current set of `tun*` link names (space-separated).
  - `wait_for_new_tun_ip <pre_snapshot>` — waits ≤10s for a NEW `tun*` link that has an inet address; echoes its name on success, `die`s on timeout.

- [ ] **Step 1: Write the helpers**

Create `docker-build/net/common.sh`:
```bash
#!/bin/bash
# Shared helpers for the VPN mode scripts. Sourced, not executed.

log() { echo "[vpn] $*" >&2; }
die() { echo "[vpn] FATAL: $*" >&2; exit 1; }

# Probe that nftables writes work — the same nf_tables netlink path sing-box's
# auto_redirect uses. Fails loudly with a specific message so the generic
# sing-box "configure tun interface: permission denied" is never the only clue.
nft_preflight() {
    if sudo nft add table inet __devbox_probe 2>/dev/null \
       && sudo nft delete table inet __devbox_probe 2>/dev/null; then
        return 0
    fi
    die "nftables writes failed — auto_redirect needs nf_tables/nf_nat in the host kernel. On Apple Silicon OrbStack this can be a host-side restriction on netfilter writes from containers."
}

# Point the container at a non-loopback resolver so DNS enters the TUN and is
# captured by sing-box (Docker's default 127.0.0.11 is loopback and leaks).
set_resolver() {
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf >/dev/null
    log "resolv.conf set to 1.1.1.1/8.8.8.8 for TUN DNS capture"
}

# Names of current tun* links, space-separated (empty if none).
snapshot_tuns() {
    ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^tun/ {print $2}' | tr '\n' ' '
}

# Wait for a tun* link not in $1 that has an inet address. Echo its name.
wait_for_new_tun_ip() {
    local pre="$1" i iface
    for i in $(seq 1 50); do            # 50 * 0.2s = 10s
        for iface in $(snapshot_tuns); do
            case " $pre " in *" $iface "*) continue;; esac   # was pre-existing
            if ip -o addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
                echo "$iface"; return 0
            fi
        done
        sleep 0.2
    done
    die "no new TUN interface with an IP appeared within 10s"
}
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
bash -n docker-build/net/common.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Unit-test the pure helper (`snapshot_tuns`) logic locally**

Run (verifies the awk parse against real `ip` output on this box):
```bash
bash -c 'source docker-build/net/common.sh; echo "tuns=[$(snapshot_tuns)]"'
```
Expected: prints `tuns=[...]` — a possibly-empty, space-separated list, no error.

- [ ] **Step 4: Commit**

```bash
git add docker-build/net/common.sh
git commit -m "feat: add shared VPN mode helpers (nft preflight, resolver, tun wait)"
```

---

### Task 3: Subscription fetch + cache (`net/fetch-subscription.sh`)

Fetches the Remnawave sing-box JSON with the correct UA, guards the format, caches the last good copy on the volume, and falls back to cache when the channel is dead.

**Files:**
- Create: `docker-build/net/fetch-subscription.sh`

**Interfaces:**
- Consumes: env `SUB_URL`; `common.sh` (`log`, `die`).
- Produces: writes validated sing-box JSON to stdout path `/var/lib/devbox/singbox/sub.json` and refreshes `/var/lib/devbox/singbox/sub.cache.json`. Exit 1 (via `die`) if neither fresh nor cached JSON is available.

- [ ] **Step 1: Write the fetcher**

Create `docker-build/net/fetch-subscription.sh`:
```bash
#!/bin/bash
# Fetch the Remnawave sing-box subscription JSON, guard its format, cache it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CACHE_DIR=/var/lib/devbox/singbox
CACHE="${CACHE_DIR}/sub.cache.json"
OUT="${CACHE_DIR}/sub.json"
UA="SFA/1.11 (io.nekohasekai.sfa) sing-box"

mkdir -p "${CACHE_DIR}"
[ -n "${SUB_URL:-}" ] || die "SUB_URL is not set (required for VPN_MODE=singbox)"

tmp="$(mktemp)"
ct="$(curl -fL -sS -A "$UA" --max-time 20 -w '%{content_type}' -o "$tmp" "$SUB_URL" 2>/dev/null || true)"

if [[ "$ct" == *application/json* ]] && jq empty "$tmp" 2>/dev/null; then
    cp "$tmp" "$CACHE"                       # refresh last-good
    cp "$tmp" "$OUT"
    rm -f "$tmp"
    log "subscription fetched and cached"
elif [ -s "$tmp" ] && ! [[ "$ct" == *application/json* ]]; then
    rm -f "$tmp"
    die "panel did not return sing-box JSON (content-type: ${ct:-none}); check SUB_URL / User-Agent"
elif [ -f "$CACHE" ]; then
    rm -f "$tmp"
    cp "$CACHE" "$OUT"
    log "subscription channel unreachable — using cached config"
else
    rm -f "$tmp"
    die "subscription unreachable and no cached config on the volume"
fi
echo "$OUT"
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
bash -n docker-build/net/fetch-subscription.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Live smoke test against the real subscription (format guard)**

Run (uses the known-good UA; redacts secrets):
```bash
mkdir -p /tmp/vp && SUB_URL='https://vpn.example.net/sub/REDACTED' \
  bash -c 'CACHE_DIR=/tmp/vp; UA="SFA/1.11 (io.nekohasekai.sfa) sing-box";
    ct=$(curl -fL -sS -A "$UA" --max-time 20 -w "%{content_type}" -o /tmp/vp/s.json "$SUB_URL");
    echo "ct=$ct"; jq -e ".inbounds and .outbounds" /tmp/vp/s.json >/dev/null && echo "JSON-OK"'
```
Expected: `ct=application/json; charset=utf-8` and `JSON-OK`.

- [ ] **Step 4: Verify the format guard rejects the base64 (wrong-UA) response**

Run:
```bash
curl -fL -sS -A 'sing-box' --max-time 20 -w 'ct=%{content_type}\n' -o /tmp/vp/b.json 'https://vpn.example.net/sub/REDACTED'
jq empty /tmp/vp/b.json 2>&1 | head -1 || echo "rejected-as-nonJSON (correct)"
```
Expected: `ct=text/plain; charset=utf-8`, and `jq empty` errors → confirms a bare-UA body would be rejected by the guard.

- [ ] **Step 5: Commit**

```bash
git add docker-build/net/fetch-subscription.sh
git commit -m "feat: fetch+cache Remnawave sing-box subscription with format guard"
```

---

### Task 4: Image-owned base config (`net/singbox-base.json`)

The headless TUN base used by `hostproxy` (and the reference TUN shape). Author-controlled, so it already has the correct `auto_redirect`/`strict_route`/`auto_detect_interface`. The host SOCKS port is substituted at runtime.

**Files:**
- Create: `docker-build/net/singbox-base.json`

**Interfaces:**
- Produces: a sing-box config with a `__HOST_SOCKS_PORT__` integer placeholder in the socks outbound, consumed by `mode-hostproxy.sh`.

- [ ] **Step 1: Write the base config**

Create `docker-build/net/singbox-base.json`:
```json
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [{ "tag": "google", "address": "8.8.8.8" }],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": false,
      "stack": "mixed",
      "sniff": true
    }
  ],
  "outbounds": [
    { "type": "socks", "tag": "proxy", "server": "host.docker.internal", "server_port": __HOST_SOCKS_PORT__, "version": "5" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy",
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" }
    ]
  }
}
```

- [ ] **Step 2: Verify it is valid sing-box config once the port is substituted**

Run (substitute a sample port, then `sing-box check` inside the built image):
```bash
sed 's/__HOST_SOCKS_PORT__/1080/' docker-build/net/singbox-base.json > /tmp/vp/base.json
docker compose run --rm -v /tmp/vp/base.json:/tmp/base.json:ro --entrypoint sing-box devbox check -c /tmp/base.json && echo CHECK-OK
```
Expected: `CHECK-OK` (no schema errors). If `sing-box check` complains, fix the JSON and re-run.

- [ ] **Step 3: Commit**

```bash
git add docker-build/net/singbox-base.json
git commit -m "feat: add image-owned headless sing-box base config for hostproxy"
```

---

### Task 5: singbox mode (`net/mode-singbox.sh`)

Ties Tasks 2-3 together: preflight, DNS, fetch, structural jq-patch, `sing-box check`, start, wait for TUN. Exports the discovered interface for danted.

**Files:**
- Create: `docker-build/net/mode-singbox.sh`

**Interfaces:**
- Consumes: `common.sh`, `fetch-subscription.sh`; env `SUB_URL`.
- Produces: a running `sing-box` process; writes the discovered TUN iface name to `/run/devbox-vpn-iface`.

- [ ] **Step 1: Write the mode script**

Create `docker-build/net/mode-singbox.sh`:
```bash
#!/bin/bash
# VPN_MODE=singbox — sing-box TUN fed by the Remnawave VLESS+Reality subscription.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
mkdir -p /var/lib/devbox/singbox

nft_preflight
set_resolver

SRC="$("${DIR}/fetch-subscription.sh")"          # validated sub.json path

# Structural patch only (no coupling to tags/servers/keys):
#  - TUN inbound: Docker-compatible transparent routing
#  - route: force loop-prevention regardless of what the panel emitted
jq '(.inbounds[] | select(.type=="tun")) |= . + {auto_redirect:true, strict_route:false}
    | .route.auto_detect_interface = true' "$SRC" > "$CFG"

sing-box check -c "$CFG" || die "sing-box check failed on the fetched config ($SRC)"

sudo pkill -x sing-box 2>/dev/null || true       # avoid clash_api/mixed-in port clash on restart
pre="$(snapshot_tuns)"
sudo sing-box run -c "$CFG" >/var/log/sing-box.log 2>&1 &
log "sing-box started (singbox mode); waiting for TUN..."

iface="$(wait_for_new_tun_ip "$pre")"
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
bash -n docker-build/net/mode-singbox.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Verify the jq patch produces valid config from the real subscription**

Run (uses the live sub from Task 3 Step 3):
```bash
jq '(.inbounds[] | select(.type=="tun")) |= . + {auto_redirect:true, strict_route:false}
    | .route.auto_detect_interface = true' /tmp/vp/s.json > /tmp/vp/patched.json
jq -e '(.inbounds[]|select(.type=="tun")|.auto_redirect)==true
   and (.inbounds[]|select(.type=="tun")|.strict_route)==false
   and .route.auto_detect_interface==true' /tmp/vp/patched.json >/dev/null && echo PATCH-OK
docker compose run --rm -v /tmp/vp/patched.json:/tmp/p.json:ro --entrypoint sing-box devbox check -c /tmp/p.json && echo CHECK-OK
```
Expected: `PATCH-OK` and `CHECK-OK`.

- [ ] **Step 4: Commit**

```bash
git add docker-build/net/mode-singbox.sh
git commit -m "feat: singbox mode — fetch, patch, check, run sing-box TUN"
```

---

### Task 6: hostproxy mode (`net/mode-hostproxy.sh`)

Same engine, static host-SOCKS outbound. No subscription.

**Files:**
- Create: `docker-build/net/mode-hostproxy.sh`

**Interfaces:**
- Consumes: `common.sh`, `singbox-base.json`; env `HOST_SOCKS_PORT`.
- Produces: a running `sing-box`; writes discovered TUN iface to `/run/devbox-vpn-iface`.

- [ ] **Step 1: Write the mode script**

Create `docker-build/net/mode-hostproxy.sh`:
```bash
#!/bin/bash
# VPN_MODE=hostproxy — sing-box TUN forwarding everything to the host's SOCKS5.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
mkdir -p /var/lib/devbox/singbox
[ -n "${HOST_SOCKS_PORT:-}" ] || die "HOST_SOCKS_PORT is not set (required for VPN_MODE=hostproxy)"

nft_preflight
set_resolver

sed "s/__HOST_SOCKS_PORT__/${HOST_SOCKS_PORT}/" "${DIR}/singbox-base.json" > "$CFG"
sing-box check -c "$CFG" || die "sing-box check failed on the hostproxy config"

sudo pkill -x sing-box 2>/dev/null || true
pre="$(snapshot_tuns)"
sudo sing-box run -c "$CFG" >/var/log/sing-box.log 2>&1 &
log "sing-box started (hostproxy mode -> host.docker.internal:${HOST_SOCKS_PORT}); waiting for TUN..."

iface="$(wait_for_new_tun_ip "$pre")"
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
bash -n docker-build/net/mode-hostproxy.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add docker-build/net/mode-hostproxy.sh
git commit -m "feat: hostproxy mode — sing-box TUN to host SOCKS5"
```

---

### Task 7: wireguard mode (`net/mode-wireguard.sh`)

The current `wg-quick` loop lifted verbatim from `entrypoint.sh`, plus a fail-fast guard so an empty config dir does not leave danted binding a dead interface.

**Files:**
- Create: `docker-build/net/mode-wireguard.sh`
- Reference: `docker-build/entrypoint.sh:56-61` (the current WG loop being lifted)

**Interfaces:**
- Produces: WireGuard interface(s) up; writes the WG iface name to `/run/devbox-vpn-iface` (the first config's basename).

- [ ] **Step 1: Write the mode script (loop lifted verbatim + guard)**

Create `docker-build/net/mode-wireguard.sh`:
```bash
#!/bin/bash
# VPN_MODE=wireguard — current behaviour: bring up every /etc/wireguard/*.conf.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

mapfile -t confs < <(sudo find /etc/wireguard -maxdepth 1 -type f -name '*.conf' 2>/dev/null)
[ "${#confs[@]}" -gt 0 ] || die "no *.conf found in /etc/wireguard — place your WireGuard config in ./wireguard/"

first_iface=""
for cfg in "${confs[@]}"; do
    iface="$(basename "$cfg" .conf)"
    [ -z "$first_iface" ] && first_iface="$iface"
    log "bringing up WireGuard interface ${iface}..."
    sudo wg-quick up "${iface}" || log "wg-quick up ${iface} failed"
done
echo "$first_iface" | sudo tee /run/devbox-vpn-iface >/dev/null
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
bash -n docker-build/net/mode-wireguard.sh && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add docker-build/net/mode-wireguard.sh
git commit -m "feat: wireguard mode — lift wg-quick loop + fail-fast on empty config"
```

---

### Task 8: danted template

Turn `danted.conf` into a template whose `external:` interface is filled at runtime. Body otherwise byte-for-byte identical.

**Files:**
- Create: `docker-build/danted.conf.tmpl`
- Delete: `docker-build/danted.conf`

**Interfaces:**
- Produces: `danted.conf.tmpl` with a single `__EXTERNAL_IFACE__` placeholder on the `external:` line.

- [ ] **Step 1: Create the template**

Create `docker-build/danted.conf.tmpl` (identical to current `danted.conf` except the `external:` line):
```
logoutput: stderr

internal: 0.0.0.0 port = 1080
external: __EXTERNAL_IFACE__

clientmethod: none
socksmethod: none

user.privileged: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
```

- [ ] **Step 2: Remove the old static conf**

Run:
```bash
git rm docker-build/danted.conf
```

- [ ] **Step 3: Commit**

```bash
git add docker-build/danted.conf.tmpl
git commit -m "refactor: danted.conf -> template with per-mode external interface"
```

---

### Task 9: Rewrite entrypoint dispatch + danted render

Wire everything together. Keep the persist-config block (lines 1-54) verbatim; replace the WG+danted tail (lines 56-68) with mode dispatch, danted render, danted start, and the final `exec`.

**Files:**
- Modify: `docker-build/entrypoint.sh` (replace lines 56-68; keep 1-54)

**Interfaces:**
- Consumes: env `VPN_MODE`; the mode scripts; `/run/devbox-vpn-iface`; `danted.conf.tmpl`.
- Produces: the fully-started container (VPN up, danted up), then `exec "$@"`.

- [ ] **Step 1: Replace the WG+danted tail with the dispatcher**

In `docker-build/entrypoint.sh`, delete from the `while IFS= read -r cfg` WireGuard loop (line ~56) through the danted block (line ~66), i.e. everything between the grok symlink block and the final `exec "$@"`. Replace with:
```bash
# --- VPN mode dispatch -------------------------------------------------------
NET_DIR=/usr/local/lib/devbox-net
case "${VPN_MODE:-}" in
    singbox)   "${NET_DIR}/mode-singbox.sh" ;;
    hostproxy) "${NET_DIR}/mode-hostproxy.sh" ;;
    wireguard) "${NET_DIR}/mode-wireguard.sh" ;;
    "")  echo "[vpn] FATAL: VPN_MODE is not set. Use singbox | hostproxy | wireguard." >&2; exit 1 ;;
    *)   echo "[vpn] FATAL: unknown VPN_MODE='${VPN_MODE}'. Use singbox | hostproxy | wireguard." >&2; exit 1 ;;
esac

# --- danted (SOCKS5 for the host), external interface per active mode ---------
IFACE="$(cat /run/devbox-vpn-iface 2>/dev/null || true)"
[ -n "$IFACE" ] || { echo "[vpn] FATAL: no active VPN interface recorded" >&2; exit 1; }
sed "s/__EXTERNAL_IFACE__/${IFACE}/" /etc/danted.conf.tmpl | sudo tee /etc/danted.conf >/dev/null
echo "[vpn] starting SOCKS5 (danted) on :1080 via ${IFACE}..."
sudo danted -f /etc/danted.conf -D || echo "[vpn] danted failed to start"

exec "$@"
```

- [ ] **Step 2: Update the Dockerfile to COPY the net/ scripts and template**

In `docker-build/Dockerfile`, replace the `COPY ... danted.conf` line with the template, and add the net scripts. Near the existing COPY block (~lines 126-129), change:
```dockerfile
COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=root:root resolvconf-shim.sh /usr/local/sbin/resolvconf
COPY --chown=root:root danted.conf.tmpl /etc/danted.conf.tmpl
COPY --chown=root:root net/ /usr/local/lib/devbox-net/
COPY --chown=root:root devbox-motd.sh /etc/devbox-motd.sh
```
And in the following `RUN chmod` line, add the net scripts to the executable set:
```dockerfile
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/sbin/resolvconf /etc/devbox-motd.sh \
        /usr/local/lib/devbox-net/*.sh \
    && chmod 644 /etc/danted.conf.tmpl /usr/local/lib/devbox-net/singbox-base.json
```

- [ ] **Step 3: Syntax-check the entrypoint and build**

Run:
```bash
bash -n docker-build/entrypoint.sh && echo ENTRY-OK
docker compose build devbox 2>&1 | tail -15
```
Expected: `ENTRY-OK`; build succeeds.

- [ ] **Step 4: Verify fail-fast on missing/invalid VPN_MODE**

Run:
```bash
docker compose run --rm -e VPN_MODE= devbox true 2>&1 | grep -i 'VPN_MODE is not set' && echo UNSET-OK
docker compose run --rm -e VPN_MODE=bogus devbox true 2>&1 | grep -i "unknown VPN_MODE" && echo BOGUS-OK
```
Expected: `UNSET-OK` and `BOGUS-OK`, each with a non-zero container exit.

- [ ] **Step 5: Commit**

```bash
git add docker-build/entrypoint.sh docker-build/Dockerfile
git commit -m "feat: VPN_MODE dispatch in entrypoint + per-mode danted render"
```

---

### Task 10: Compose + env + wireguard dir

Grant `/dev/net/tun`, switch the WG mount to a directory, pass the new env vars, and document them. This is the task that makes the whole thing runnable.

**Files:**
- Modify: `docker-compose.yml`
- Modify: `.env.example`
- Create: `wireguard/.gitkeep`

**Interfaces:**
- Consumes: everything above.
- Produces: a runnable stack for all three modes.

- [ ] **Step 1: Update `docker-compose.yml`**

Add `/dev/net/tun`, the env vars, and change the WG mount. In the `devbox` service:

Add under `environment:` (after `TZ`):
```yaml
      VPN_MODE: ${VPN_MODE}
      SUB_URL: ${SUB_URL:-}
      HOST_SOCKS_PORT: ${HOST_SOCKS_PORT:-}
```
Add a `devices:` block (sibling of `cap_add:`):
```yaml
    devices:
      - /dev/net/tun
```
Change the WireGuard volume line from:
```yaml
      - "${WG_CONFIG}:/etc/wireguard/${WG_CONFIG}:ro"
```
to:
```yaml
      - "./wireguard/:/etc/wireguard/:ro"
```
(Do not add a compose-level `dns:` — DNS is handled per-mode in the scripts.)

- [ ] **Step 2: Update `.env.example`**

Replace the `WG_CONFIG` section with the new variables:
```bash
# Egress mode (REQUIRED). One of:
#   singbox   - sing-box TUN using your Remnawave VLESS+Reality subscription (SUB_URL)
#   hostproxy - tunnel all traffic into a SOCKS5 proxy on the host (HOST_SOCKS_PORT)
#   wireguard - bring up ./wireguard/*.conf (the previous default behaviour)
VPN_MODE=singbox

# singbox mode: your Remnawave subscription URL (the panel returns sing-box JSON).
SUB_URL=

# hostproxy mode: the port of your host's own SOCKS5 proxy, dialed via
# host.docker.internal. Distinct from SOCKS_HOST_PORT below.
HOST_SOCKS_PORT=

# wireguard mode: place your WireGuard config(s) in ./wireguard/*.conf.
# The filename (minus .conf) becomes the interface name (letters, digits,
# '-', '_'; max 15 chars). MIGRATION: move an existing wg-peer9.conf into
# ./wireguard/ and remove the old WG_CONFIG variable.
```
Leave the `SOCKS_HOST_PORT` block as-is (it is the danted publish port).

- [ ] **Step 3: Create the wireguard dir and migrate the existing config**

Run:
```bash
mkdir -p wireguard
[ -f wg-peer9.conf ] && git mv wg-peer9.conf wireguard/wg-peer9.conf 2>/dev/null || mv wg-peer9.conf wireguard/ 2>/dev/null || true
touch wireguard/.gitkeep
```
Expected: `wireguard/wg-peer9.conf` exists; project root no longer has the stray conf.

- [ ] **Step 4: Validate compose**

Run:
```bash
VPN_MODE=singbox docker compose config >/dev/null && echo COMPOSE-OK
```
Expected: `COMPOSE-OK` (compose file parses, variables interpolate).

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example wireguard/.gitkeep
git commit -m "feat: compose+env for VPN_MODE, /dev/net/tun, wireguard dir mount"
```

---

### Task 11: End-to-end runtime verification (all three modes)

Prove each mode actually tunnels, danted publishes to the host, and DNS does not leak. This is the acceptance gate; no code, only driving the real container.

**Files:** none (verification only).

- [ ] **Step 1: singbox mode — egress goes through the VPN exit**

Run (with a real `SUB_URL` in `.env`, `VPN_MODE=singbox`):
```bash
docker compose up -d
sleep 8
docker exec devbox curl -fsS --max-time 15 https://api.ipify.org; echo
docker compose logs devbox 2>&1 | grep -E 'TUN up|danted|FATAL' | tail
```
Expected: prints an IP that is the VPN exit (KZ/FI/DE node), **not** your ISP IP; logs show `TUN up: tun*` and danted starting; no FATAL.

- [ ] **Step 2: Host SOCKS publish still works (auto_redirect didn't break the bridge)**

Run (from the host; uses the published `SOCKS_HOST_PORT`):
```bash
PORT=$(grep -E '^SOCKS_HOST_PORT=' .env | cut -d= -f2)
curl -fsS --max-time 15 --socks5 127.0.0.1:${PORT} https://api.ipify.org; echo
```
Expected: same VPN exit IP as Step 1 — the host reaches the internet through the container's tunnel.

- [ ] **Step 3: DNS does not leak**

Run:
```bash
docker exec devbox sh -c 'cat /etc/resolv.conf; getent hosts example.com'
```
Expected: `resolv.conf` shows `nameserver 1.1.1.1` (not `127.0.0.11`); the lookup resolves (through the tunnel).

- [ ] **Step 4: wireguard mode regression (unchanged behaviour)**

Run:
```bash
docker compose down
VPN_MODE=wireguard docker compose up -d
sleep 8
docker exec devbox curl -fsS --max-time 15 https://api.ipify.org; echo
docker compose logs devbox 2>&1 | grep -E 'WireGuard|danted|FATAL' | tail
```
Expected: prints the WireGuard exit IP; danted up with `external: wg-peer9`; no FATAL. (If the WG endpoint is DPI-blocked, this may time out — that is the original problem, not a regression; confirm the interface came up in logs.)

- [ ] **Step 5: hostproxy mode (if a host SOCKS5 is available)**

Run (with `HOST_SOCKS_PORT` pointing at a live host SOCKS5, `VPN_MODE=hostproxy`):
```bash
docker compose down
VPN_MODE=hostproxy HOST_SOCKS_PORT=<your-host-socks-port> docker compose up -d
sleep 8
docker exec devbox curl -fsS --max-time 15 https://api.ipify.org; echo
```
Expected: egress IP is the host VPN's exit. (Skip if no host SOCKS5 is running; note it as untested.)

- [ ] **Step 6: Tear down and record results**

Run:
```bash
docker compose down
```
Record which modes were verified and any that were skipped (e.g., hostproxy without a host proxy). Do not claim a mode works if it was not exercised.

---

## Self-Review

**Spec coverage** (each spec section → task):
- Modes / VPN_MODE required → Task 9 (dispatch, fail-fast).
- singbox minimal-intervention jq patch (auto_redirect, strict_route, auto_detect_interface) → Task 5.
- Fetch + cache + format guard + UA → Task 3.
- Preflight nftables probe → Task 2 (`nft_preflight`), used in Tasks 5-6.
- hostproxy base config + integer server_port → Tasks 4, 6.
- danted per-mode external interface, template → Tasks 8, 9.
- TUN discovery = first new tun* with IP → Task 2 (`wait_for_new_tun_ip`), used 5-7.
- Startup ordering (wait IP → render danted → start) → Tasks 5-7 + 9.
- DNS per-mode resolv.conf rewrite, wireguard untouched → Task 2 (`set_resolver`), Tasks 5-6; wireguard mode (Task 7) never calls it.
- sing-box v1.13.14 pinned + SHA256 + arch-aware → Task 1.
- Compose: /dev/net/tun, no privileged, WG dir mount, no compose dns → Task 10.
- .env: VPN_MODE, SUB_URL, HOST_SOCKS_PORT, WG migration → Task 10.
- wireguard fail-fast on empty dir → Task 7.
- Error-handling table rows → Tasks 3 (fetch/format), 5-6 (preflight/check/TUN), 7 (empty WG), 9 (mode dispatch).
- Secrets never logged → no task echoes config bodies; verification Steps redact.
- Testing/verification section → Task 11.

No gaps found.

**Placeholder scan:** No TBD/TODO/"handle errors"/"similar to". The two intentional runtime placeholders (`__HOST_SOCKS_PORT__`, `__EXTERNAL_IFACE__`, `<SHA_AMD64>`) are explicitly resolved by their tasks (sed substitution / Step-1 lookup).

**Type/name consistency:** helper names (`nft_preflight`, `set_resolver`, `snapshot_tuns`, `wait_for_new_tun_ip`, `log`, `die`) defined in Task 2 are used with identical names in Tasks 5-7. `/run/devbox-vpn-iface` is written by Tasks 5-7 and read by Task 9 — consistent. `__EXTERNAL_IFACE__` (Task 8) matches the sed in Task 9. `__HOST_SOCKS_PORT__` (Task 4) matches the sed in Task 6. Script dir `/usr/local/lib/devbox-net/` consistent between Dockerfile COPY (Task 9) and entrypoint `NET_DIR` (Task 9).
