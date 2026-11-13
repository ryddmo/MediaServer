---
name: nas-underhall
description: Run a periodic health check of the whole Ugreen NAS media stack — gluetun/VPN/killswitch, qBittorrent, every container's health, host OS unattended-upgrades, disk headroom, and the VPS-hosted ntfy dependency. Use this when Stefan asks for a status report, health check, or "is anything wrong/outdated on the NAS", whether or not he uses those exact words — "check the NAS", "anything I should look at?", etc. Runs on demand or scheduled (via launchd). Reports only — NEVER makes a change (an upgrade, a fix, a config edit) without asking first. Not for planning a structural change (see nas-arkitekt instead).
---

# nas-underhall

A reporter, not an actor. Walks a fixed checklist over the whole NAS media
stack and delivers a short, readable summary — what's fine, what needs
attention, and what needs Stefan to decide something. Never performs the fix
itself; if something needs fixing, the next step is asking, not having
already done it.

Assumes SSH access to `ugreen` and `vps` (see `~/.ssh/config`). Everything
below is read-only against both hosts — nothing is written, restarted, or
removed during this pass.

## Checklist

Go through every item in order. Don't skip one because an earlier one looked
bad — gather everything before writing the report, so Stefan gets a complete
picture in one pass instead of several follow-up rounds.

### 1. qBittorrent's bound interface — the single highest-value check here

```sh
ssh ugreen "docker exec qbittorrent grep '^Session\\\\Interface=' /config/qBittorrent/qBittorrent.conf"
```

Must be `tun0`. If it's `lo`, downloads are silently dead regardless of what
gluetun's own health status says — this is the exact failure mode that cost
11 hours once already, with zero error anywhere in qBittorrent's own log.
Flag this above everything else if it's wrong.

### 2. Container health across the stack

```sh
ssh ugreen "docker ps -a --format '{{.Names}}: {{.Status}}'"
ssh ugreen "docker inspect gluetun --format 'Health: {{.State.Health.Status}}'"
ssh ugreen "for c in gluetun qbittorrent prowlarr sonarr radarr bazarr jellyfin flaresolverr; do printf '%s: ' $c; docker inspect $c --format '{{.RestartCount}}'; done"
```

Flag anything not `running`, anything `unhealthy`, and any restart count
that's climbed since the last check (one-off restarts happen; a climbing
count means something's flapping).

### 3. gluetun port-forwarding — is it actually active, not just "healthy"

```sh
ssh ugreen "docker logs gluetun --since 6h 2>&1 | grep -iE 'port forward|forwarded'"
```

"Healthy" only means the process is alive, not that port forwarding is
working. The recurring PIA Frankfurt cert mismatch
(`certificate is valid for Server-X-4a, not Server-X-2a`) is a known,
accepted trade-off (see `SETUP.md`) — don't re-flag it as new unless the
*symptom* has changed, i.e. qBittorrent's interface (checklist item 1) is
back on `lo`. If it's just the same recurring retry-without-crashing, that
belongs in "known, not actionable," not "needs attention."

### 4. unattended-upgrades — did the nightly run succeed, anything stuck

```sh
ssh ugreen "systemctl show ugreen-unattended-upgrade.service -p Result,ExecMainStatus --value"
ssh ugreen "systemctl list-timers ugreen-unattended-upgrade.timer --no-pager"
ssh ugreen "apt list --upgradable 2>/dev/null"
```

Note the last run's result, whether the timer is actually scheduled (not
masked again — the vendor image has done this once), and any pending package
that's **not** in the deliberate blacklist (`linux-image-`, `linux-headers-`,
`docker-ce`, `docker-ce-cli`, `containerd.io`) — that would mean the
origin-pattern filter missed something real. Packages pending *because*
they're blacklisted, or because they're from an origin the filter doesn't
match (seen before: `base-files`, backports-track `libdrm`/mesa packages,
`tailscale` from an unmatched origin) are expected — mention them once,
don't treat as new each time.

### 5. Disk headroom

```sh
ssh ugreen "df -h /volume2"
```

Flag if it's climbing toward full — Docker's data-root and all appdata live
there.

### 6. The VPS this stack's alerting depends on

```sh
ssh vps "docker ps --format '{{.Names}}: {{.Status}}'"
ssh vps "df -h /"
```

Lighter-touch than the NAS checks — `notify.ryddmo.se` runs on this VPS, so a
dead VPS means every ntfy alert this stack relies on goes dark with reduced
redundancy (Uptime Kuma's own "Ntfy" monitor now alerts via a separate Gmail
channel for exactly this reason — see `SETUP.md`). Just confirm it's up;
don't go deep on the unrelated personal apps sharing that box.

## Report format

Keep it short and readable — not a wall of raw command output. Use this
shape:

```
## NAS status — <date>

**All clear:** <one line per item that needs nothing>

**Needs attention:** <items with concrete what/why, but no action taken>

**Needs a decision:** <things where Stefan has to choose something — e.g. an
image worth upgrading, a package blacklist that might need revisiting>
```

If everything's clear: say so briefly, don't print empty headers for the
other two categories.

## Important

- **Never make a change during this pass.** If item 1 finds `lo` instead of
  `tun0`, or item 4 finds a real problem — say so in the report, wait for
  the go-ahead. The only exception is if Stefan explicitly asked for both
  the check and the fix in the same request ("check the NAS and fix
  whatever you find").
- If this runs scheduled (via `launchd`) and everything's clear: keep the
  response short — no reason to repeat the full checklist narrative every
  time nothing changed.
