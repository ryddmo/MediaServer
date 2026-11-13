---
name: nas-arkitekt
description: Plan structural/architectural changes to the Ugreen NAS homelab stack (new container/service in docker-compose.yml, changed deploy/auth/secrets handling, changed VPN/killswitch behavior, changed backup or notification wiring, a new dependency) — use this BEFORE building anything, whenever a task changes how the stack is built or how a service is operated, not just what it contains. Do NOT use for routine health checks (see nas-underhall) or for a plain content/config change within an already-established pattern.
---

# nas-arkitekt

Governs how structural changes to the Ugreen NAS stack get planned, so each
one stays inside the patterns that already proved out through this stack's
own incidents — deliberately, not by habit, and not by quietly inventing a
new pattern mid-task. Scoped to the whole NAS media stack (gluetun,
qBittorrent, the Arr apps, Jellyfin, the host OS, ntfy wiring), not a single
app's internals. This is the counterpart to `nas-underhall` (routine
reporting) — this skill is for *before* something is built, that one is for
*after*, on a schedule.

## 1. When this skill applies

Anything that makes the stack *built differently*, not just *containing
more*:

- A new service/container in `docker-compose.yml`, a new external dependency
  (a new image, a new API/service it talks to).
- Changed deploy mechanism (how compose changes reach the NAS, how a
  container gets recreated).
- Changed auth/secrets handling (how a credential is stored, shared, or
  protected).
- Changed VPN/killswitch behavior, changed backup, or changed
  notification/alerting wiring.
- Anything spanning more than one of: the NAS itself, the `MediaServer`
  repo, the `vps` host, or how they depend on each other.

Does **not** apply to: a normal content change (adding a show/movie,
adjusting a quality profile), or a routine health check of what already
exists (that's `nas-underhall`).

## 2. Sources — read before proposing a plan

- **`SETUP.md`** (this repo's root) — the running, detailed history: what's
  built, why, and every gotcha already hit. Read the numbered gotchas list
  and the "Open follow-ups" section specifically — each one is a lesson that
  cost a real incident or debugging session.
- **Memory** (if available):
  `~/.claude/projects/-Users-stefanrydin-Documents-dev-nas/memory/jellyfin-arr-stack-progress.md`
  and `.../pia-vpn-killswitch-and-subscription.md`.
- The `vps` repo's `STATUS.md` and `infra-arkitekt` skill, if the change
  touches anything shared with the VPS (ntfy, Tailscale, backup target) —
  this NAS stack is not an isolated system; `notify.ryddmo.se` alerting in
  particular depends on that VPS being healthy.

If a new plan would contradict what these describe: that's not automatically
wrong, but it means the deviation must be deliberate and stated out loud to
Stefan, not silent.

## 3. Established decisions (starting point, not a proposal)

Already-made calls, proven through this stack's own incidents. A new plan
should work within them, not re-litigate them in passing. If a task genuinely
requires breaking one: say so explicitly and ask, never assume.

1. **Gluetun's kill-switch must stay structurally enforced**, not just
   configured — qBittorrent only ever reaches the internet through `tun0`.
   Any change here must preserve that a VPN/port-forward failure cannot
   silently leak traffic outside the tunnel, and must not reintroduce the
   `Session\Interface=lo` silent-death failure mode (see gotcha #13).
2. **Whenever `gluetun` is recreated, `qbittorrent` must be recreated right
   after** — it shares gluetun's network namespace and will silently point
   at a dead one otherwise.
3. **PIA stays on OpenVPN for now**, living with the Frankfurt cert bug
   rather than switching to WireGuard — a deliberate call, not an oversight.
   Revisit only if the "recovered" ntfy alert stops firing for an extended
   period, and only with Stefan's explicit go-ahead.
4. **`unattended-upgrades`' blacklist (`linux-image-`, `linux-headers-`,
   `docker-ce`, `docker-ce-cli`, `containerd.io`) is deliberate**, protecting
   hand-tuned kernel/Docker-storage config from the NAS migration. Don't
   narrow or remove it without Stefan's explicit sign-off, and never enable
   `Automatic-Reboot`.
5. **Secrets never land in chat.** Generate/compare server-side; when Stefan
   needs to read one himself (an app password, a restic password), he
   retrieves it from his own terminal — never through the `!` channel, which
   still round-trips through the transcript. Never `bash -x`/debug-trace a
   script that handles a secret.
6. **ntfy topics are plain, non-secret slugs** (`ugreen-vpn-killswitch`,
   `ugreen-system-updates`, `ugreen-architect`) — unlike the `vps` repo's
   stockpicker-style rotated-secret topics, these can be referenced directly
   in scripts/compose without the rotation ceremony. Don't over-apply the
   `vps` repo's secret-topic handling here; it's a different trust model by
   design.
7. **A new systemd unit on the NAS needs the same scrutiny as any other
   change** — the vendor image already silently strips some expected units
   (see the `apt-daily-upgrade.timer` gotcha); verify a new unit is actually
   enabled and has a real next-run time, don't assume `systemctl enable`
   succeeded just because it didn't error.
8. **Cloud-scheduled routines and `CronCreate` cannot reach the home LAN at
   all** — any "run this periodically against the NAS" idea needs either a
   NAS-native systemd timer (deterministic, no LLM) or a `launchd` LaunchAgent
   on Stefan's Mac running `claude -p` headless (keeps the judgment layer) —
   see `nas-underhall` for the current choice and why.

## 4. Workflow

1. Read the sources in §2.
2. For anything non-trivial, use plan mode — lay out the change, the
   services it touches, what gets recreated, and how it'll be verified
   (not just "exits 0" — a real end-to-end check, matching this stack's own
   track record of catching bugs that only showed up under real use).
3. Ask Stefan explicitly about genuine design choices (which trade-off, which
   blast radius is acceptable) — don't guess and don't silently pick for him
   on anything irreversible or security-relevant.
4. After the change ships: update **both** `SETUP.md` and relevant memory —
   a structural change that isn't documented here will just get rediscovered
   the hard way next time, the same way the qBittorrent `lo` incident was.
