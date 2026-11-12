# MediaServer — Jellyfin + Arr Stack on the Ugreen NAS

Docker Compose stack running on the same Ugreen DXP4800 Plus NAS documented in the
`nas` repo's `UGOS-SETUP.md` (hostname `dxp4800plus-2b0.local`, LAN IP `192.168.86.43`).
Runs **alongside** the existing native Plex install, not replacing it — same media
library, two media servers.

No secrets live in this file. The real `.env` (PIA credentials, etc.) exists only on the
NAS at `/volume2/docker/compose/.env`, never committed — see `.env.example` for the
shape of it.

## What's running

| Service | Image | URL | Purpose |
|---|---|---|---|
| Gluetun | `qmcgaw/gluetun` | — | VPN gateway (PIA), gives qBittorrent a kill-switched tunnel |
| qBittorrent | `linuxserver/qbittorrent` | `http://192.168.86.43:8080` | Download client, shares Gluetun's network namespace |
| FlareSolverr | `flaresolverr/flaresolverr` | `http://192.168.86.43:8191` | Solves Cloudflare challenges for some indexers |
| Prowlarr | `linuxserver/prowlarr` | `http://192.168.86.43:9696` | Indexer manager, syncs indexers into Sonarr/Radarr |
| Sonarr | `linuxserver/sonarr` | `http://192.168.86.43:8989` | TV automation |
| Radarr | `linuxserver/radarr` | `http://192.168.86.43:7878` | Movie automation |
| Bazarr | `linuxserver/bazarr` | `http://192.168.86.43:6767` | Subtitles (OpenSubtitles.com), watches Sonarr+Radarr |
| Jellyfin | `linuxserver/jellyfin` | `http://192.168.86.43:8096` | Media server #2, alongside Plex |

Everything is LAN-only by design — no ports are forwarded on the router, matching the
same security posture as Plex/SSH on this box (see `UGOS-SETUP.md`). Remote access, if
ever wanted, would go over Tailscale rather than opening anything to the internet.

## Directory layout (on the NAS)

```
/volume2/docker/
├── compose/
│   ├── docker-compose.yml   # mirrors this repo's copy
│   └── .env                 # NOT in git — PIA creds, PUID/PGID, TZ
├── appdata/<service>/       # each container's own config, ryddmo:admin 775
├── downloads/{incomplete,complete}/
└── engine/                  # Docker's + containerd's own data — root:root 0711,
                              # deliberately separate from the ryddmo:admin ownership
                              # on everything else
```

Media itself is untouched, still at `/volume1/Media/{Movies,TV}` — Sonarr/Radarr/
Bazarr/Jellyfin all mount that same path as `/data/media` inside their containers, so
new imports show up for Plex and Jellyfin immediately with no path translation.

**Known trade-off, accepted knowingly**: downloads live on Volume 2, media lives on
Volume 1 — two different filesystems, so Sonarr/Radarr's import step can never hardlink,
only copy+delete. Not a problem at this download volume, just worth knowing if imports
ever feel slow.

## Gotchas hit getting this running (read before touching Docker on this NAS again)

1. **Docker wouldn't start at all — same root cause as the Tailscale install.** A stray
   systemd-wide `GODEBUG=tlskyber=0` env var (see `UGOS-SETUP.md`) hard-crashes any
   sufficiently recent Go binary, which includes both `dockerd` and `containerd`. Fixed
   with scoped drop-ins, **one per service** (both needed it, not just Docker):
   ```
   /etc/systemd/system/docker.service.d/override.conf
   /etc/systemd/system/containerd.service.d/override.conf
   ```
   each containing:
   ```ini
   [Service]
   Environment=GODEBUG=
   ```
2. **Docker couldn't create any containers even once the daemon was running** —
   `failed to mount ... overlay ... invalid argument`. Cause: this NAS's entire `/` is
   *itself* an overlay mount (how UGOS's base OS is built: squashfs layers + an upper
   writable layer). The kernel won't stack Docker's overlay2 storage driver on top of an
   already-overlay root. Fixed by pointing both engines at a real ext4 partition
   (`/volume2`) instead of the default `/var/lib/...`:
   - `/etc/docker/daemon.json` → `{"data-root": "/volume2/docker/engine/docker"}`
   - `/etc/containerd/config.toml` → `root = "/volume2/docker/engine/containerd"`
3. **`docker` group membership is root-equivalent** (any member can trivially get host
   root via a container bind-mount) — a bigger grant than the narrow NOPASSWD sudoers
   scope already set up for the `claude` SSH account (`UGOS-SETUP.md`:
   apt-get/systemctl/tailscale/mkdir/chown/chmod/tee only). Had Stefan run
   `sudo usermod -aG docker ryddmo` and `... claude` himself rather than doing it via the
   scoped sudo list.
4. **Gluetun's PIA region name must match its own exact list** — `Germany` is rejected
   (`the region specified is not valid`, with a full list of valid names dumped in the
   error); the right value is `DE Frankfurt`, same server the DS214play's old DSM-native
   VPN profile used.
5. **Whenever `gluetun` is recreated** (config/env change, image update),
   **`qbittorrent` must be recreated right after**:
   ```
   docker compose up -d --force-recreate qbittorrent
   ```
   Otherwise it keeps its network namespace pinned to the now-dead old `gluetun`
   container — WebUI goes to HTTP 000 with nothing useful in the logs to explain why.
6. **`/volume1/Media` needed `g+w`.** It was `claude:admin` `755` (fine for Plex reading
   it, not for Sonarr/Radarr/Bazarr writing into it as PUID 1000/PGID 10 — in the `admin`
   group, but group only had read+execute). Fixed with `chmod -R g+w /volume1/Media`.
7. **qBittorrent's own Default Save Path defaults to `/downloads`**, which doesn't exist
   in this compose file's mount layout (`/data/downloads` is what's actually mounted).
   Looked exactly like a dead/unseeded torrent — "Errored" status, 0 bytes written, blank
   Save Path in the UI — but had nothing to do with seeders or trackers. Fixed in
   qBittorrent's own **Tools → Options → Downloads**: Default Save Path →
   `/data/downloads`, incomplete-torrents path → `/data/downloads/incomplete`.
8. **Radarr's "Any" quality profile has no size ceiling.** A real test grab picked a
   58GB 2160p REMUX over a normal ~2-7GB 1080p release, purely because nothing in the
   profile discouraged it. Fixed by editing the `HD-1080p` profile to disable
   `Remux-1080p` specifically (left everything else in that profile as-is). Sonarr's
   `HD-1080p` profile never had a Remux option to begin with, so TV didn't need the same
   fix. **Use `HD-1080p`, not `Any`, when adding movies.**
9. **Prowlarr → Sonarr/Radarr indexer sync doesn't perfectly mirror categories.** EZTV
   correctly didn't sync to Sonarr while it was in a Cloudflare-error state (expected —
   unhealthy indexers don't get pushed). Separately, Pirate Bay never synced to Radarr
   despite being healthy with a Movies category tagged — unresolved, not chased further
   since Radarr already has 1337x + YTS for movies.
10. FlareSolverr was needed to get past Cloudflare for `1337x` and `EZTV`. Wired in via
    Prowlarr → **Settings → Indexers → Indexer Proxies** → FlareSolverr →
    `http://flaresolverr:8191`. It shows up "Disabled" by default even once added —
    has to be explicitly toggled on.
11. **Gluetun's own port-forwarding log entry for the qBittorrent sync command is
    tagged `ERROR` even on success.** It's just gluetun labeling the command's stderr
    output that way regardless of outcome — the wget call itself returned exit `0` and
    HTTP `200` both times it was checked. Don't take that log line at face value; verify
    against qBittorrent's actual `listen_port` (via its API) instead.

## PIA port forwarding

Enabled on Gluetun directly (`VPN_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=true` so it
only picks PIA servers that support it). Kept `DE Frankfurt` as the region — it does
support forwarding.

The forwarded port changes each time it's (re)assigned, so qBittorrent's listening port
is kept in sync **automatically** via `VPN_PORT_FORWARDING_UP_COMMAND` /
`..._DOWN_COMMAND` on the `gluetun` service — these call qBittorrent's own API
(`POST /api/v2/app/setPreferences`) from inside gluetun's container, hitting
`127.0.0.1:8080` since qBittorrent shares its network namespace.

**Requires** qBittorrent's **Tools → Options → WebUI → "Bypass authentication for
clients on localhost"** to be enabled — safe here since that only ever accepts calls
from inside the same private container network namespace, never anywhere external.

Confirmed working end to end: PIA assigned port `43217`, qBittorrent's
`listen_port` was automatically updated to match, with `random_port`/`upnp` both
correctly left off (UPnP wouldn't help here anyway — the whole point is that inbound
connections now arrive straight through the VPN tunnel, not via the home router). No
host port mapping was needed for this — the existing `6881` mapping on `gluetun` is
unrelated/unused by the forwarded port.

## Per-app setup notes

- **PUID/PGID**: `1000`/`10` everywhere (`ryddmo`:`admin`) — matches the ownership
  `Media` already has.
- **Auth**: Prowlarr/Sonarr/Radarr/Bazarr all got Forms login +
  "Disabled for Local Addresses", Allowed Hosts =
  `192.168.86.43, dxp4800plus-2b0.local, localhost`.
- **Indexers** (Prowlarr): 1337x, The Pirate Bay, YTS, EZTV — all public, no account
  needed. TorrentGalaxy wasn't in Prowlarr's indexer list, skipped.
- **Download client**: qBittorrent, reached by Sonarr/Radarr/Prowlarr at host `gluetun`,
  port `8080` (not `localhost` — they're separate containers).
- **Bazarr**: newer versions use "Languages Profiles" rather than a flat language list —
  created one (`sv`+`en`), set as default for both Series and Movies under
  **Settings → Languages**. OpenSubtitles.com provider reuses the same account the old
  `subtitle_fetch.py` script (see `DS214PLAY-SETUP.md`) already used.
- **Jellyfin**: QuickSync enabled under **Playback → Transcoding** — Hardware
  acceleration: Intel QuickSync (QSV), device `/dev/dri/renderD128`, hardware decoding
  ticked for `H264`/`HEVC`/`HEVC 10bit` only (matches what's actually in the library per
  the old Plex codec audit — no VC1/VP8/VP9/AV1 content exists, so left those off).
  **Confirmed working for real** by inspecting a live transcode's ffmpeg command line —
  `-hwaccel vaapi` + `-codec:v:0 h264_qsv`, not a software fallback.

## Verified end-to-end (2026-11-11/12)

Two full real-world runs through the entire pipeline (Prowlarr search → Radarr grab →
qBittorrent VPN-gated download → auto-import into `/volume1/Media/Movies` → Bazarr
auto-subtitle-fetch → visible in Jellyfin), both with public-domain films:

- *Night of the Living Dead* (1968) — first run, also where the qBittorrent save-path
  bug (#7 above) and the Radarr "Any" profile size problem (#8) were caught and fixed.
- *Nosferatu* (1922) — second run, after both fixes, grabbed a normal 7GB 1080p release
  cleanly with zero manual intervention.

Gluetun's kill switch was also verified for real, not just assumed: stopping the
container left qBittorrent's network namespace with **no route to the internet at all**
(tested against a raw IP, not just a DNS failure) — confirmed no leak before trusting it
with real traffic.

## Open follow-ups

- Whether to eventually retire Plex now that Jellyfin works well — no decision made,
  running both indefinitely for now.
- Remote (Tailscale) access to these web UIs — currently LAN-only by design, revisit if
  ever wanted.
