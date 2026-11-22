# Multi-owner boxes — the plan (#253 member 4, #287)

**Status:** plan, not built. The station before it ships in 0.11.0: shared
tenants (`box grant --service NAME --share GROUP`, `box --as NAME`).

## Where this starts

@danmt, 2026-08-21 (D1 on #253): *"Ultimately what I want is multi-owner
boxes."* One box, visible to and operable by more than one person, with
**visibility**, **access** and **lifecycle** as separate rights. #161 holds
the desk research; this page is its plan.

Three things exist today:

1. **The admin answer** (D2). Staging users in `incus-admin` share `default`,
   at the cost of the full daemon socket. The README documents it.
2. **Shared tenants** (0.11.0, #287). A service grant's project is operated
   by a host group through sudo to the service user, restricted to the box
   binary. The unit of sharing is the **whole project**: every member holds
   every box in it, and every credential inside them. It is coarse, honest,
   and needs nothing from Incus beyond what the restricted tier already uses.
3. **This plan**: the unit of sharing becomes **one box**, and the three
   rights split.

## The measurement (#253 member 2)

The question: over incus-user's socket, does a granted user's
`incus --project <another project> …` **hard-refuse**, or does it silently
answer with their own project's view?

It is measured on a real daemon by `drill/multiuser.sh` phase **(s)**: a
hand-made project holding a profile, read by a granted user. The rehearsal's
audit line records the answer (`hard-refused` or `silently-scoped`), and the
drill fails if the profile is ever **readable**. Whichever it is, the
consequence is the same: **the restricted tier cannot be widened to a second
project by adding a key to `box grant`.** incus-user is per-uid by
construction. Any per-box sharing therefore rides Incus's authorization
model, not the tier's confinement.

## The mechanism: the authorization scriptlet

Incus's fine-grained authorization model already splits the three rights per
instance, and declares every relation over users **and groups**:

| right | entitlements |
|---|---|
| visibility (`box list`) | `can_view` |
| access (`box shell`, `box exec`) | `can_exec`, `can_access_console`, `can_access_files`, `can_connect_sftp` |
| lifecycle (`box rm`, `down`, `restore`, snapshots) | `can_edit`, `can_update_state`, `can_manage_snapshots`, `can_manage_backups` |

There are two drivers:

- **The scriptlet** (`authorization.scriptlet`). An `authorize(details,
  object, entitlement)` function evaluated inside the daemon, with no external
  service. **This is the design target.** box would own a scriptlet that
  reads co-ownership from the instance itself: a key such as
  `user.box.owners.view` / `.access` / `.lifecycle` holding host group names,
  resolved against the caller's groups. It would be installed by
  `setup-host` and converged like the firewall.
- **OpenFGA** (`authorization.openfga.*`). The documented answer, but it
  requires running an OpenFGA server yourself: an external service to run,
  secure and back up, on a host whose promise is one script and a hardened
  bridge. It's costed here so the choice is visible, not because it's the plan.

**The open question the scriptlet must answer first:** how a caller on
incus-user's socket is identified to `authorize()` (its `details.Username`
and protocol), and whether a scriptlet decision can admit a caller into an
instance outside their `user-<uid>` project at all, or only narrow what they
already reach. If it can only narrow, multi-owner boxes live in a shared
project whose access the scriptlet narrows per box. That is exactly the
shared-tenant shape, refined per instance.

## The landmine

If `authorization.client.tls-restricted` is set to anything other than
`tls`, *"the project list of the client certificate are no longer consulted,
and a restricted certificate may gain access well beyond the projects it is
limited to."* Any design that leans on restricted certificates must pin that
key to `tls` and have `box doctor` assert it, or the confinement is
decorative. The scriptlet design does not use restricted certificates, but a
host that later adds one inherits the landmine. **Pin it in `setup-host`
regardless.**

## What a build would deliver, in order

1. The scriptlet, its key vocabulary, and `setup-host` installing and
   converging it, plus a doctor check that `tls-restricted` is `tls`.
2. `box share <box> --view|--access|--lifecycle GROUP` and `box unshare`,
   which write the keys. They are refused for the irreversible lifecycle
   right unless the owner asks for it explicitly.
3. The credential warning (#287's SHOUT) at `--access`, the right that
   reaches the credentials.
4. Drill phases on a real daemon for each right: granted, refused, revoked.

## Why not yet

Shared tenants cover the staging case that started this, with no new
privilege model. The scriptlet is daemon-wide policy code that box would own
on every host, and its admission question above is unanswered. D4 on #253
allows this window to end on a plan and a README section. It ends on a plan,
a README section and a working coarse share.
