<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Twin counterpart contract

Copy this file to the root of the repository that adopted the twin workflow,
name it `TWIN_COUNTERPART.md`, and fill in every section. This is the only place
where the twin helpers' repository-specific facts may live; nothing under the
twin folder may hardcode them.

Delete the guidance under each heading once the heading is filled in.

## Roles

- **Reference (read-only):** `<the original implementation the port must match>`
- **Port (code under test):** `<the implementation being verified>`

## Checkouts and paths

| What | Path | Read-only? |
|---|---|---|
| Reference checkout | `<path>` | yes |
| Port checkout | `<path>` | no |
| Evidence root | `<path>\runs` | git-ignored |

## Legs

Names must match the `legs` object in `TWIN-VERIFICATION.json`.

| Role | Leg name | How to start | How to stop |
|---|---|---|---|
| Reference | `<leg>` | `<command>` | `<command>` |
| Port | `<leg>` | `<command>` | `<command>` |

## Fork and action commands

- Reference fork: `<command or tool calls>`
- Reference action + capture: `<command or tool calls>`
- Port fork: `<command or tool calls>`
- Port action + capture: `<command or tool calls>`

Prefer the repository's own wrappers. `twin_item.ps1 capture` exports
`TWIN_SHOT_PATH`; a capture command should write its frame there.

## Capture rules

- Viewport/size both legs: `<size>`
- Frame format: `<png/etc>`
- Where the reference evidence comes from (fresh run, archived frames, source):
  `<path>`

## Windows environment

- Launcher and arguments for each leg: `<command>`
- Ports, window titles, bridge/socket settings: `<list>`
- Screenshot path and profile reset: `<how>`

## Accepted differences

Differences that are accepted rather than fixed (platform chrome, font
rendering, timing) and their reason:

- `<difference>` - `<reason>`
