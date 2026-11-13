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
9. **Prowlarr → Sonarr/Radarr indexer sync doesn't perfectly mirror categories.**
   Pirate Bay never synced to Radarr despite being healthy with a Movies category
   tagged — unresolved, not chased further since Radarr already has 1337x + YTS for
   movies.
10. FlareSolverr was needed to get past Cloudflare for `1337x` and `EZTV`. Wired in via
    Prowlarr → **Settings → Indexers → Indexer Proxies** → FlareSolverr →
    `http://flaresolverr:8191`. It shows up "Disabled" by default even once added —
    has to be explicitly toggled on.
11. **The FlareSolverr proxy is scoped by tag, not applied globally.** It only routes
    requests for indexers that have the `flaresolverr` tag assigned (Prowlarr →
    Settings → Indexer Proxies → the proxy's own `tags` field). `1337x` got tagged when
    FlareSolverr was set up; `EZTV` didn't — so EZTV kept hitting Cloudflare directly
    and failing indefinitely (looked like a flaky/unreliable Cloudflare challenge, but
    was really just a missing tag). Fixed by adding the `flaresolverr` tag to EZTV's
    indexer settings; confirmed in FlareSolverr's own logs that it then actually
    received and solved the `eztvx.to` challenge. **If any future indexer needs
    FlareSolverr, it needs this same tag — it isn't automatic.**
12. **Gluetun's own port-forwarding log entry for the qBittorrent sync command is
    tagged `ERROR` even on success.** It's just gluetun labeling the command's stderr
    output that way regardless of outcome — the wget call itself returned exit `0` and
    HTTP `200` both times it was checked. Don't take that log line at face value; verify
    against qBittorrent's actual `listen_port` (via its API) instead.
13. **qBittorrent silently stopped downloading for ~11 hours (2026-11-13) — not a
    tracker/VPN problem, an interface-binding one.** `VPN_PORT_FORWARDING_DOWN_COMMAND`
    deliberately forces qBittorrent's `current_network_interface` to `lo` whenever port
    forwarding isn't healthy (a soft kill-switch, so torrent traffic can't leak outside
    the tunnel). That morning, gluetun's OpenVPN tunnel flapped several times → each
    teardown fired `DOWN_COMMAND` → qBittorrent got parked on `lo` → the final
    reconnect's port-forward startup then crashed outright on a PIA-side bug (see below),
    and because the *old* `gluetun:latest` image crashed instead of retrying,
    `UP_COMMAND` never fired again to restore `tun0`. Result: qBittorrent sat dead on
    `lo` for 11 hours with **zero errors in qBittorrent's own log** — it looked exactly
    like a dead tracker/VPN issue, not an interface problem. Fixed by: (a) manually
    resetting `Session\Interface`/`Session\InterfaceName` back to `tun0` in
    `qBittorrent.conf` (had to stop the container first, edit via a throwaway root
    container on the same volume, then restart — editing it live risks qBittorrent's own
    shutdown overwriting the fix), and (b) pulling a newer `gluetun:latest` image, which
    fixed the crash-forever bug (now retries the port-forward negotiation automatically
    every 15–60s without touching `DOWN_COMMAND`/`UP_COMMAND` on a merely-failed-to-start
    attempt). **If downloads ever go dead again with 0 peers/seeds across every torrent,
    check `Session\Interface` in `qBittorrent.conf` before anything else** — it won't
    show up as an error anywhere.

## PIA subscription

Runs until **2027-09-22**. qBittorrent only works through this tunnel (kill-switch
enforced — see gotcha #13), so torrenting stops entirely once it lapses, unless renewed
or a replacement VPN provider is configured in this repo's `docker-compose.yml`.

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

**Known, accepted, ongoing issue (as of 2026-11-13): PIA's Frankfurt gateway has a
recurring TLS cert bug that breaks port-forward renegotiation.** Gluetun's attempt to
find the port-forward API address fails with
`tls: failed to verify certificate: x509: certificate is valid for Server-X-4a, not
Server-X-2a` — the gateway IP answers with a cert for a different logical server than
the one the OpenVPN session is actually on. This is upstream/PIA-side, not a gluetun or
compose misconfiguration. On the current (updated) gluetun image it retries forever
every 15–60s without crashing or touching qBittorrent's interface — so **downloads keep
working** even while this is active, only inbound-peer efficiency is reduced. Considered
switching PIA from OpenVPN to WireGuard (gluetun's own recommended fix for this exact
bug class) but decided against it for now — smaller blast radius to just live with it
and get notified (see ntfy section below) than to re-verify the whole VPN/killswitch
chain under a different protocol. Revisit if the "recovered" ntfy alert stops firing for
an extended period.

## Completed-download cleanup (qBittorrent seeding limits)

Sonarr/Radarr's "Remove Completed Downloads" (on by default for the qBittorrent client)
only actually removes a download once **qBittorrent itself** reports seeding as
finished — it doesn't just remove immediately after import. With no seeding limits
configured, qBittorrent seeds forever, so finished/imported downloads just sat in the
client indefinitely (looked like a bug, wasn't one — just no seeding policy set).

Fixed by setting global seeding limits in qBittorrent (**Tools → Options → BitTorrent →
Seeding Limits**): ratio limit `1.0`, seeding time limit `1440` minutes (24h), action on
limit reached left as the default **Pause** (not delete — Sonarr/Radarr do the actual
removal once qBittorrent reports the torrent as paused/finished).

## One Piece re-grab loop (anime numbering mismatch)

Sonarr's queue ballooned to **120 duplicate entries**, all for the identical
`One Piece S02 Season 2 2026 1080p NF WEBRip ... x265-Rapta` release, each one flagged
`One or more episodes expected in this release were not imported or missing`. Root
cause: TheTVDB lists 22 episodes for Season 2, but this release group (a Netflix-dub
repackaging) only ever shipped 8 under that label — a release that can **never**
satisfy Sonarr's expectation, so it kept re-grabbing the same thing forever instead of
ever marking it "complete" and cleaning up. This is a known, long-standing One Piece
problem (release groups, TheTVDB, and absolute numbering all disagree with each other
across its 1000+ episodes), not specific to this setup.

Fixed by bulk-clearing the stuck queue entries
(`DELETE /api/v3/queue/bulk?removeFromClient=false`, since the already-imported files
were fine and didn't need touching) and unmonitoring Season 2 specifically to stop
future re-grabs. **Watch for this pattern on any show with messy source numbering**
(anime especially) — a queue that keeps growing with duplicates of the same release is
the tell, and unmonitoring the specific offending season is the fix, not troubleshooting
the download itself.

Separately found and manually cleaned up: several *fully* complete, already-imported
downloads (unrelated to the loop above) were still sitting in qBittorrent — caused by
the seeding-limits issue above, not a second bug.

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

## ntfy alerting (added 2026-11-13)

Self-hosted ntfy at `https://notify.ryddmo.se/` — runs on the `vps` host
(`kind-puma`, reached over Tailscale, see the `nas` repo's memory/docs for that box).
**This is a single point of failure for every alert below**: if that VPS goes down, all
three topics go silent simultaneously, with no fallback channel to say so.

Three topics in use:

| Topic | Fires on | Source |
|---|---|---|
| `ugreen-vpn-killswitch` | gluetun forcing qBittorrent onto `lo` (down) / restoring `tun0` (up) | `VPN_PORT_FORWARDING_DOWN_COMMAND`/`_UP_COMMAND` in this repo's `docker-compose.yml` |
| `ugreen-system-updates` | host OS security/stable package upgrades installed, or a reboot becomes required | `/usr/local/bin/ugreen-unattended-upgrade-notify.sh` on the NAS (see below) |
| `ugreen-architect` | the daily deterministic health check finds something wrong | `/usr/local/bin/ugreen-systemarkitekt-check.sh` on the NAS (see below) |

Added directly because of gotcha #13 above — the entire point is that the silent
11-hour outage shouldn't be able to repeat invisibly. All three are deliberately
**silent on success**; they only speak up when something actually needs attention.

## Host OS unattended upgrades (added 2026-11-13)

The NAS's underlying Debian 12 (bookworm) base doesn't actually ship a working
`apt-daily-upgrade.timer`/`.service` — `dpkg` thinks they're installed (they're in the
`apt` package's file list) but the actual unit files are missing from disk, seemingly
stripped from Ugreen's base image on purpose (likely to avoid generic Debian
auto-upgrades fighting their own vendor update channel). Rather than try to resurrect
vendor-removed functionality, a separate, fully custom mechanism was set up instead:

- `unattended-upgrades` package installed, with `/etc/apt/apt.conf.d/50unattended-upgrades`
  appended (not replaced) with NAS-specific safety overrides:
  - `Unattended-Upgrade::Package-Blacklist` adds `linux-image-`, `linux-headers-`,
    `docker-ce`, `docker-ce-cli`, `containerd.io` — these have hand-tuned
    configs/overrides from this stack's own setup (gotchas #1–#3 above, plus the kernel
    itself) and must not get silently upgraded out from under them. These packages will
    always show up as "pending" in `apt list --upgradable` — that's expected, they need
    **manual** review, not automatic.
  - `Unattended-Upgrade::Automatic-Reboot "false"` — never auto-reboot a NAS serving
    Jellyfin/qBittorrent/etc. unattended; the notify script flags if a reboot becomes
    required so it can be done deliberately instead.
- Own systemd units (`/etc/systemd/system/ugreen-unattended-upgrade.{service,timer}`),
  daily at 04:30 (±20min), calling `/usr/local/bin/ugreen-unattended-upgrade-notify.sh`
  — runs `unattended-upgrade -v`, then posts to `ugreen-system-updates` if anything was
  installed or a reboot is now required, or if the run itself failed.
- **First real run (during setup) installed ~110 packages** in one go — a large backlog
  had accumulated, including some sensitive ones (`grub-efi-amd64-signed`,
  `shim-signed`, `systemd`, `bash`, `postgresql-15`). All verified healthy afterward (no
  errors, `InstCount=0 DelCount=0 BrokenCount=0` on the next check, all containers still
  up) — mentioned here so it isn't a surprise if the dpkg changelog/history looks like a
  lot happened at once on that date.

## systemarkitekt (added 2026-11-13)

Two halves, one purpose — catching silent breakage/staleness before it compounds, same
motivation as gotcha #13:

- **Manual**: the `/systemarkitekt` skill (`~/.claude/skills/systemarkitekt/SKILL.md` on
  Stefan's Mac) — an on-demand, judgment-based architecture review covering this repo,
  the `nas` repo, and the `vps` host. Run it whenever a "is anything outdated/risky on
  the NAS?" check is wanted.
- **Scheduled**: `/usr/local/bin/ugreen-systemarkitekt-check.sh` on the NAS itself, via
  `ugreen-systemarkitekt.timer` (daily 09:00 ±15min — deliberately after the 04:30
  unattended-upgrades run, so it can catch anything that run left pending). Deterministic
  shell checks only (no LLM judgment involved, since this runs unattended): qBittorrent's
  `Session\Interface`, container health/restart counts, `/volume2` disk headroom, and
  whether the upgrade timer itself is healthy. Silent unless it finds something, same
  pattern as the ntfy alerts above.

A cloud-scheduled version (Claude Code's cron-based "routines") was considered first but
doesn't work here — those run in Anthropic's sandboxed cloud infra with no network path
to the home LAN, Tailscale or not. Hence the NAS-native script instead.

## Open follow-ups

- Whether to eventually retire Plex now that Jellyfin works well — no decision made,
  running both indefinitely for now.
- Remote (Tailscale) access to these web UIs — currently LAN-only by design, revisit if
  ever wanted.
- The PIA Frankfurt port-forwarding cert bug (see above) — living with it for now,
  revisit switching to WireGuard if it stops self-resolving.
- `ugreen-architect`/`ugreen-system-updates`/`ugreen-vpn-killswitch` all depend on the
  same VPS for ntfy — no fallback alert channel exists if that VPS itself goes down. Not
  addressed yet, just flagged.
