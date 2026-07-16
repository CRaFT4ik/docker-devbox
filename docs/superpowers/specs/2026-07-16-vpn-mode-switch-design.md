# Devbox VPN mode switch — design

**Date:** 2026-07-16
**Status:** Design, pending implementation plan
**Revision:** 3 (round-2 review: enforce loop prevention, per-mode DNS,
IP-assignment gate, runtime TUN discovery, pinned sing-box version, WG fail-fast +
migration)

## Problem

The devbox container currently routes all its traffic through a WireGuard
interface brought up at startup. Russian DPI (ТСПУ) now blocks the WireGuard
endpoint, so the container loses connectivity. We need the container's egress
strategy to be selectable at launch, so the user can switch to a working
transport without rebuilding the image.

## Goals

- Switch egress strategy via a single env var, chosen at container start.
- Add a censorship-resistant path: sing-box with a TUN interface, fed from the
  user's Remnawave VLESS+Reality subscription (works today under ТСПУ).
- Add a path that tunnels all container traffic into a SOCKS5 proxy already
  running on the host (the user's working VPN).
- Keep the existing WireGuard behaviour available, unchanged.
- **Robustness is the primary acceptance criterion.** No fragile coupling to the
  subscription panel's internal structure (server tags, squad names, key
  layout). The container is a user-independent *tool*; per-user secrets come
  only from outside (env + mounts), never baked into the image.
- **Minimal intervention in existing code.** The WireGuard/danted path is lifted
  into its own file unchanged; the existing entrypoint's persist-config block is
  untouched.

## Non-goals

- Parsing `vless://` share links by hand (the panel emits ready sing-box JSON).
- Changing the container's Docker network model (stay on bridge; do not switch
  to `network_mode: host`).
- Rewriting the existing WireGuard / danted logic.
- Auto-migrating transports at runtime, health-checking, or failover between
  modes. One mode per container start.

## Key facts established during design

Verified against the live subscription `https://vpn.example.net/sub/…` and against
sing-box 1.12/1.13 docs + issues on 2026-07-16.

### Subscription (Remnawave)

- **Remnawave selects the response format by User-Agent.**
  - UA `sing-box` (bare word) → **base64 list of `vless://` links** (`text/plain`).
  - UA `SFA/1.11 (io.nekohasekai.sfa) sing-box` → **full sing-box `config.json`**
    (`application/json`). We use this UA.
- The panel returns a **complete** sing-box config: `dns`, `route`,
  `experimental`, `outbounds` (a `selector` named `→ Remnawave` over 🇰🇿/🇫🇮/🇩🇪
  VLESS+Reality nodes, `xtls-rprx-vision`, `server_name: icloud.com`, `utls`
  fingerprints `ios`/`randomized`), and includes a `tun-in` inbound plus a
  `mixed-in` listener on `127.0.0.1:2412`.
- The panel's `route` block sets **`auto_detect_interface: true`** — this is the
  mechanism that prevents sing-box's own VLESS traffic from re-entering the TUN
  (see "Routing loop", below). Confirmed present.
- The panel's `tun-in` sets `auto_route: true` and `strict_route: true` but **no
  `auto_redirect`**, `mtu: 9000`, `interface_name: tun125`,
  `endpoint_independent_nat: true`, and a `platform.http_proxy` block. It also
  ships `experimental.clash_api` (yacd web UI on `127.0.0.1:9090`) and a
  `cache_file` (`remnawave.db`).
- The panel's `utls`/Reality masquerade (`icloud.com`, fp `ios`) is a
  **deliberate, working** ТСПУ-evasion choice. We do **not** strip it. Generic
  "remove utls" advice does not apply to this panel's config.
- Under ТСПУ, the same VLESS+Reality profile is more reliable on the **sing-box**
  core than on xray-core (observed in the wild). This, plus native Remnawave
  sing-box-JSON export and single-binary operation, is why sing-box is the
  engine.

### sing-box TUN behaviour in Docker (fact-checked)

- **`strict_route: true` breaks inbound Docker-bridge traffic** (issue #2700):
  replies to a published port would exit via TUN while arriving on eth0, and
  strict reverse-path filtering drops them. Our danted publish
  (`127.0.0.1:${SOCKS_HOST_PORT}:1080`) would break. → We set **`strict_route:
  false`** together with **`auto_redirect: true`**. `auto_redirect` (nftables
  REDIRECT via pure-Go netlink — **no `nft` binary needed**) is the
  officially-recommended Docker-compatible path.
- **`auto_redirect` needs kernel modules** `nf_tables`, `nf_nat`, `nfnetlink`,
  `nfnetlink_queue` present on the host kernel. `NET_ADMIN` + `/dev/net/tun` are
  the only caps/devices required — **no `--privileged`, no `SYS_MODULE`**.
- **OrbStack caveat (M1/M2/M3):** OrbStack has a documented restriction on
  iptables-NAT writes from inside containers (orbstack#1001); whether it extends
  to nftables netlink writes is unconfirmed. A missing/blocked `nf_tables`
  surfaces as a **generic** `configure tun interface: permission denied` FATAL,
  which is easy to misread as a caps problem. → The singbox path must run a
  **preflight kernel check** and emit a clear diagnostic (see below).
- **Routing loop is prevented automatically** when `route.auto_detect_interface:
  true` (present in the panel config): sing-box binds its own outbound sockets to
  the detected physical interface, bypassing TUN. Our existing
  `net.ipv4.conf.all.src_valid_mark=1` sysctl enables the SO_MARK backup path. No
  explicit VLESS-endpoint exclusion is needed.
- **DNS to `127.0.0.11` (Docker embedded resolver) leaks** — it is loopback
  traffic that TUN/`hijack-dns`/`auto_redirect` cannot intercept. → In the
  singbox/hostproxy modes the **mode script rewrites `/etc/resolv.conf`** to a
  non-loopback resolver (e.g. `1.1.1.1`) after mode dispatch, so DNS enters the
  TUN and is captured. This is done in the mode scripts, **not** via Docker's
  compose-level `dns:` — a global `dns:` would also change the wireguard mode's
  pre-tunnel DNS state and disable Docker service discovery. The wireguard mode
  is left entirely on its existing resolvconf-shim behaviour, untouched.

### danted `external:` (fact-checked)

- `external:` binds outbound sockets to the **IP of the named interface**; if the
  interface is absent at startup, danted refuses to start. The current
  `danted.conf` hardcodes `external: wg-peer9`, which **does not exist** in the
  singbox/hostproxy modes → danted would die. `external: eth0` is **wrong** too
  (source-IP/egress mismatch against a TUN default route). → `danted.conf` must
  name the **active egress interface per mode**: the TUN interface in
  singbox/hostproxy, `wg-peer9` in wireguard. `external: 0.0.0.0` is not
  supported.

## Chosen approach

**sing-box is the single TUN engine** for the two new modes. The modes differ
only by which outbound the traffic ultimately takes — the TUN inbound and local
routing infrastructure are identical. WireGuard remains a separate,
self-contained mode.

### Modes (`VPN_MODE`, required — no default)

| `VPN_MODE`  | Behaviour |
|-------------|-----------|
| `singbox`   | sing-box brings up a TUN interface; outbounds come from the user's Remnawave subscription (VLESS+Reality). |
| `hostproxy` | sing-box brings up the same TUN interface; a single `socks` outbound forwards everything to `host.docker.internal:${HOST_SOCKS_PORT}` (the host's working VPN). |
| `wireguard` | Current behaviour: `wg-quick up` for every `/etc/wireguard/*.conf`, then danted. Logic lifted verbatim, plus one fail-fast guard: if no `*.conf` is found, exit 1 (otherwise danted would later bind `external: wg-peer9` to a non-existent interface and die silently). |

If `VPN_MODE` is empty or unrecognised, the entrypoint **fails fast** with a
clear message and a non-zero exit.

`danted` (SOCKS5 on `:1080`, published to the host at
`127.0.0.1:${SOCKS_HOST_PORT}`) runs in **all three modes**, so the host can
always reach the internet through the container's active transport. Its
`external:` interface is set per mode (see danted handling).

## Config handling (mode `singbox`) — "minimal intervention"

The panel emits a valid, complete sing-box config. We treat it as a black box and
apply a small, structural patch via `jq` (independent of tags, servers, emoji,
keys, outbound structure):

- on the TUN inbound (`type == "tun"`): set `auto_redirect: true`,
  `strict_route: false`
- on the `route` block: **force `auto_detect_interface: true`**

The `route.auto_detect_interface` patch is not cosmetic: it is the mechanism that
keeps sing-box's own VLESS packets from re-entering the TUN (routing loop). The
panel currently emits it, but relying on a black-box field for a
correctness-critical property is exactly the fragile coupling we forbid — so we
set it ourselves rather than trust it. Setting it is idempotent and does not
change outbound selection. (This is a deliberate, bounded exception to "touch
nothing but the TUN inbound": loop prevention is infrastructure, like the TUN
inbound itself, and belongs to the tool.)

Everything else — outbounds, the `→ Remnawave` selector (server rotation), DNS
servers, the rest of `route`, the Reality/utls masquerade — is left exactly as
the panel produced it. GUI-only leftovers (`clash_api`, `platform.http_proxy`,
`mixed-in`) are left untouched; they bind loopback only and are harmless.
(`clash_api` on `127.0.0.1:9090` and `mixed-in` on `127.0.0.1:2412` only fail if
those ports are already taken — handled by killing any stale sing-box before
start.)

jq form (verified against jq 1.7 shipped in Ubuntu 24.04):

```sh
jq '(.inbounds[] | select(.type=="tun")) |= . + {auto_redirect:true, strict_route:false}
    | .route.auto_detect_interface = true'
```

Rationale for the two-field patch: `auto_route` alone breaks the Docker bridge
publish; `auto_redirect` is the Docker-compatible replacement and `strict_route:
false` removes the reverse-path drops that would otherwise kill our danted
publish. This is the smallest edit that makes the panel's GUI-oriented config
correct for a headless bridged container.

### Fetch + cache flow

```
fetch-subscription.sh:
  UA = "SFA/1.11 (io.nekohasekai.sfa) sing-box"
  curl -fL -sS -A "$UA" --max-time 20 "$SUB_URL" -> /tmp/sub.json
    (-f fail on HTTP error, -L follow redirects)
    success AND Content-Type contains "application/json" AND `jq empty` passes
        -> cp /tmp/sub.json  /var/lib/devbox/singbox/sub.cache.json   (refresh cache)
    otherwise (network dead, HTTP error, or non-JSON base64 came back)
        -> use /var/lib/devbox/singbox/sub.cache.json                 (last good)
             -> no cache present -> exit 1 with a clear message

mode-singbox.sh:
  mkdir -p /var/lib/devbox/singbox
  preflight: nft add table inet __devbox_probe 2>/dev/null \
             && nft delete table inet __devbox_probe 2>/dev/null
             (fails -> clear nftables diagnostic, exit 1; see below)
  source config = fetch-subscription.sh result
  jq patch: TUN inbound {auto_redirect:true, strict_route:false}
            + route.auto_detect_interface = true
        -> /var/lib/devbox/singbox/config.json
  sing-box check -c config.json   (must pass, else exit 1 naming the bad source)
  pkill -x sing-box 2>/dev/null   (avoid clash_api/mixed-in port clash on restart)
  record existing tun* links, start sing-box in background
  wait until a NEW tun* link appears AND has an inet address assigned
        (`ip addr show <iface> | grep -q 'inet '`, poll, 10s cap; else exit 1)
  export the discovered iface name for the entrypoint's danted render
  (danted started afterwards by the entrypoint, external = that TUN interface)
```

Cache lives on the existing `devbox` volume (`/var/lib/devbox`), so a successful
fetch survives container recreation and defeats the chicken-and-egg problem
(can't download the subscription over a dead channel).

### Preflight kernel check (singbox + hostproxy)

Before starting sing-box, probe that nftables writes work, using the `nft` binary
(installed in the image for exactly this purpose — see Dockerfile):

```sh
nft add table inet __devbox_probe 2>/dev/null && nft delete table inet __devbox_probe 2>/dev/null
```

This exercises the same `nf_tables` netlink path `auto_redirect` needs. It does
**not** rely on `/proc/config.gz` (absent on many kernels, including some OrbStack
VMs) and does not conflate schema validation with kernel capability. On failure,
print a specific message:

> `[vpn] nftables writes failed — auto_redirect needs nf_tables/nf_nat in the
> host kernel. On Apple Silicon OrbStack this can be a host-side restriction on
> netfilter writes from containers.`

and exit 1, so the generic sing-box `configure tun interface: permission denied`
FATAL is never the only signal.

## Config handling (mode `hostproxy`)

No subscription. We ship an image-owned base config (`singbox-base.json`) with the
correct headless TUN inbound (`auto_route:true`, `auto_redirect:true`,
`strict_route:false`, `sniff:true`), a minimal `dns`/`route` (with
`auto_detect_interface:true` and `hijack-dns`), and a placeholder outbound set.
The mode script substitutes the host SOCKS endpoint:

```json
"outbounds": [
  {"type":"socks","tag":"proxy","server":"host.docker.internal",
   "server_port":HOST_SOCKS_PORT,"version":"5"},
  {"type":"direct","tag":"direct"}
]
```

`server_port` is a JSON **integer** (unquoted) — substituted as a number, not a
string, or `sing-box check` rejects it. `route.final` points at `proxy`.

`singbox-base.json` is also the reference for the correct headless TUN inbound
shape. Like `mode-singbox.sh`, `mode-hostproxy.sh` runs the nftables preflight,
rewrites `/etc/resolv.conf` to a non-loopback resolver, and waits for the TUN
interface to come up with its IP before returning.

## danted handling (all modes)

The current `danted.conf` hardcodes `external: wg-peer9`. Because the active
egress interface differs per mode, `danted.conf` is **rendered at startup** from
a template with the interface substituted:

- `wireguard`  → `external: wg-peer9` (the WG interface, as today)
- `singbox` / `hostproxy` → `external: <tun interface name>`

The TUN interface name is **discovered at runtime**, never parsed from the panel
config (which we treat as a black box): the mode script records the set of `tun*`
links before starting sing-box, then takes the **first new `tun*` link that
appears** with an assigned inet address. This is panel-agnostic — the panel
renaming `tun125` to anything else does not matter — and avoids the contradiction
of reading `interface_name` out of a config we otherwise refuse to couple to.
danted is started **after** the TUN interface exists and has its IP (the mode
script's interface-wait gate guarantees both), so its `external:` bind always
resolves.

This is the one change to danted, and it is additive: the wireguard branch
reproduces today's exact `external: wg-peer9`.

## Startup ordering

`auto_redirect`, the TUN interface, and its IP are not instant. The mode scripts
**block until the TUN interface exists AND has an inet address assigned**
(`ip addr show <iface> | grep -q 'inet '`, 10 s cap) before returning to the
entrypoint, which then renders `danted.conf` (with `external:` = that interface)
and starts danted. Waiting for the address, not merely the link, is what
guarantees danted's `external:` bind resolves. Routes and nftables rules are
installed synchronously by sing-box before the address wait completes in
practice.

Note a small, documented gap: there is a sub-second window at startup, before
sing-box installs its nftables rules, during which outbound traffic can exit
plain (untunneled). Traffic to the Docker bridge subnet/gateway is also
intentionally not tunneled (`strict_route: false`). For a dev container this is
acceptable; it is called out so it is not later mistaken for a leak bug.

## Files

Additions + one dispatcher rewrite; existing WG/danted logic is moved, not
modified.

```
docker-build/
  entrypoint.sh                 # rewritten: persist-config block (UNCHANGED) +
                                #   dispatch on VPN_MODE + render danted.conf +
                                #   start danted, then exec "$@"
  net/
    mode-singbox.sh             # preflight, fetch+cache+patch+check, start sing-box, wait TUN
    mode-hostproxy.sh           # render host-socks base config, start sing-box, wait TUN
    mode-wireguard.sh           # existing wg-quick loop, lifted verbatim
    fetch-subscription.sh       # UA fetch (-fL), format guard, cache to volume
    singbox-base.json           # image-owned headless base: TUN inbound + route infra
    danted.conf.tmpl            # danted.conf with an EXTERNAL_IFACE placeholder
```

The existing `danted.conf` becomes `danted.conf.tmpl` (only `external:` becomes a
placeholder; everything else identical).

## Compose / image changes

`docker-compose.yml`:

```yaml
    environment:
      TZ: Europe/Moscow
      VPN_MODE: ${VPN_MODE}          # required; container refuses to start if unset/invalid
      SUB_URL: ${SUB_URL}            # required for singbox
      HOST_SOCKS_PORT: ${HOST_SOCKS_PORT}   # required for hostproxy
    devices:
      - /dev/net/tun                 # NEW — sing-box TUN needs the userspace tun device
    volumes:
      - "./wireguard/:/etc/wireguard/:ro"   # CHANGED — mount the DIRECTORY, not a single
                                            #   file, so non-WG modes start without a WG config
    # NO compose-level dns:  — DNS is set per-mode inside the mode scripts
    #   (singbox/hostproxy rewrite resolv.conf to a non-loopback resolver;
    #    wireguard keeps its resolvconf-shim). A global dns: would leak DNS
    #    pre-tunnel in wireguard mode and disable Docker service discovery.
    # cap_add: [NET_ADMIN]           # unchanged
    # sysctls: src_valid_mark        # unchanged (also backs sing-box loop prevention)
    # ports: 127.0.0.1:${SOCKS_HOST_PORT}:1080   # unchanged (danted publish, all modes)
```

- **WG mount → directory.** Today `"${WG_CONFIG}:/etc/wireguard/${WG_CONFIG}:ro"`
  mounts a single host file; in singbox/hostproxy the user may have no WG file and
  the container would fail to start (Docker creates an empty dir at a missing
  source, breaking the path). Mounting the `wireguard/` directory read-only lets
  `mode-wireguard.sh` iterate `*.conf` as it already does, and the other modes
  simply find no configs. **Migration:** existing users move `wg-peer9.conf` into
  a new `./wireguard/` directory and drop `WG_CONFIG` from `.env`. Documented in
  `.env.example` and the migration note below.
- **DNS is handled per-mode, not globally** (see mode scripts). This keeps the
  wireguard mode's DNS behaviour byte-for-byte as it is today.
- No `--privileged`, no `SYS_MODULE`. `/dev/net/tun` forwards an existing host
  device node into the container's `/dev`; it creates nothing on the host, and
  the TUN interface / routes / nftables rules live entirely inside the
  container's network namespace (exactly as `wg-peer9` does today).

`.env` / `.env.example`:

- Add `VPN_MODE=` (documented values: `singbox` | `hostproxy` | `wireguard`).
- Add `SUB_URL=` (Remnawave subscription URL; required for `singbox`).
- Add `HOST_SOCKS_PORT=` (the host's own SOCKS5 port that `hostproxy` dials via
  `host.docker.internal`; distinct from `SOCKS_HOST_PORT`).
- Replace `WG_CONFIG=` guidance: WG configs now live in `./wireguard/*.conf`
  (directory mount). **Migration for existing users:** create `./wireguard/`,
  move the existing `wg-peer9.conf` into it, remove `WG_CONFIG` from `.env`. The
  filename (minus `.conf`) is still the interface name.
- `SOCKS_HOST_PORT` stays — the port danted is **published on** to the host
  (`127.0.0.1:${SOCKS_HOST_PORT}:1080`), unrelated to the host's own VPN.

`Dockerfile`:

- Install sing-box **pinned to `v1.13.14`** (latest stable as of 2026-06-25;
  well past the 1.13.2 `hijack-dns` regression; supports `auto_redirect`,
  `inet4_address`, `endpoint_independent_nat`). Install method: download the
  official GitHub release tarball
  `sing-box-1.13.14-linux-${ARCH}.tar.gz` (ARCH = `amd64`|`arm64`, derived from
  `dpkg --print-architecture` / `TARGETARCH`), **verify its SHA256** against the
  release checksum, extract the `sing-box` binary to `/usr/local/bin`. Arch-aware
  so the image builds on both Apple-Silicon (`arm64`) and `amd64` hosts.
- Add **`nftables`** (small package) — used by the preflight `nft` probe. Keep
  `wireguard-tools`, `iproute2`, `iptables`, `dante-server`. `jq` (1.7) and
  `curl` are already present.

## Error handling

| Situation | Behaviour |
|-----------|-----------|
| `VPN_MODE` unset/invalid | exit 1, message listing valid modes |
| `singbox` mode, `SUB_URL` unset | exit 1, clear message |
| `hostproxy` mode, `HOST_SOCKS_PORT` unset | exit 1, clear message |
| Subscription fetch fails, cache exists | warn, use cached config |
| Subscription fetch fails, no cache | exit 1, clear message |
| Fetch returns non-JSON (wrong UA/URL) | exit 1, "panel did not return sing-box JSON" |
| nftables unusable (kernel/OrbStack) | exit 1, **specific** nftables diagnostic (not the generic FATAL) |
| `sing-box check` fails | exit 1, name the offending config source |
| TUN interface never appears/gets IP within 10 s | exit 1, clear message; danted not started |
| `wireguard` mode, no `*.conf` in `/etc/wireguard` | exit 1, "place your WireGuard config in ./wireguard/" (prevents danted binding a dead interface) |
| `hostproxy`, host SOCKS unreachable | sing-box starts; egress fails until host proxy is up (logged) — not fatal, mirrors WG's non-fatal startup style |
| `wireguard` mode (configs present) | unchanged from today |

## Testing / verification

- **Mode dispatch:** each `VPN_MODE` value takes the correct branch; unset/invalid
  exits non-zero with the message.
- **singbox happy path:** with a valid `SUB_URL`, config is fetched; the final
  config has `auto_redirect:true` + `strict_route:false` on the tun inbound;
  `sing-box check` passes; the tun interface comes up; egress IP is the VPN exit
  (curl an IP-echo through the container).
- **DNS not leaking (singbox/hostproxy):** a DNS lookup from inside the container
  resolves via the VPN exit, not Docker's embedded resolver (verify resolver path
  / exit IP).
- **singbox resilience:** panel unreachable + warm cache → still starts from
  cache; neither → exit 1.
- **Format guard:** a bare `sing-box` UA (base64 body) is rejected, not run.
- **nftables preflight:** on a host without nftables, the specific diagnostic is
  printed (not only the generic sing-box FATAL).
- **hostproxy:** with a host SOCKS5 up, container egress goes through it.
- **danted external per mode:** danted starts in all three modes; in
  singbox/hostproxy its `external:` names the live TUN interface and outbound
  proxying works; in wireguard it is `wg-peer9` exactly as before.
- **Port publish intact:** in `singbox` and `hostproxy`, the host can still reach
  `127.0.0.1:${SOCKS_HOST_PORT}` (i.e. `auto_redirect` + `strict_route:false` did
  not break the bridge publish).
- **Non-WG start:** with no file in `./wireguard/`, singbox/hostproxy start
  cleanly (directory mount, no missing-file failure).
- **wireguard regression:** unchanged behaviour still works.
- Secrets (uuid, reality keys, subscription token) never printed to logs.
