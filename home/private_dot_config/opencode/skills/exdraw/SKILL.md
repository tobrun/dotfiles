---
name: exdraw
description: Draw and refine diagrams on a live Excalidraw canvas with the exdraw CLI. Use when asked to create, edit, lay out, screenshot, export or import Excalidraw diagrams, or to convert Mermaid to Excalidraw.
---

# exdraw

Run `exdraw <command>` (declared app, launcher on PATH; exdraw is not an
npm package, so never use `npx` for it).
The canvas server auto-starts at http://127.0.0.1:3000.
Ask the user to open that URL in a browser; `shot` and `mermaid` need an open tab (exit code 4 otherwise).
Run `exdraw <command> -h` when you need flag details.

| Task | Command |
|---|---|
| Create elements | `exdraw add -` with a JSON array on stdin |
| Update one element | `exdraw set <id> key=value ...` |
| Delete | `exdraw rm <id> ...` |
| Many changes at once | `exdraw apply -` with `{"create":[],"update":[{"id","set":{}}],"delete":[]}` |
| Inspect the scene | `exdraw ls` (one line per element), `ls <id> --full` |
| Verify visually | `exdraw shot --out out.png`, then read the PNG |
| Save / load | `exdraw export --out f.excalidraw`, `exdraw import f.excalidraw --replace` |
| Mermaid | `exdraw mermaid diagram.mmd` |

## Element format

- Always pass your own `id` so later `set`, `rm` and `ls` calls need no lookup.
- `text` on a rectangle, ellipse or diamond becomes a centered label.
- Arrows: `{"type":"arrow","startElementId":"a","endElementId":"b","text":"optional"}`. Bindings and positions are computed for you.
- Standalone text: `{"type":"text","x":..,"y":..,"text":"..","fontSize":20}`.
- Style keys: `backgroundColor`, `strokeColor`, `fillStyle` ("solid" for filled shapes), `strokeWidth`, `roundness` (`{"type":3}` for rounded corners).

## Layout rules

- Origin is top left, y grows downward. Place nodes on a grid.
- Node width: `max(160, characters * 12)`; height 60 for a one-line label, 80 for two lines.
- Gaps: 80 to 120 px between tiers, 40 to 60 px between siblings, 50 px padding inside zones.
- Never put `text` on a large background zone rectangle; Excalidraw centers it over everything inside. Use a separate text element at the zone's top left.
- Avoid arrows that cross zones or other nodes; reorder nodes instead. Keep arrow labels under 12 characters and rare.

## Quality loop

After every `add` or `apply`: run `exdraw shot`, look at the image, and check for truncated labels, overlapping shapes, arrows crossing nodes, and uneven spacing.
Fix with `exdraw set <id> x=.. y=.. width=..`, then shoot again.
Say what you saw and what you fixed. Do not declare a diagram done without a screenshot.

## Errors

Exit 3: canvas unreachable, run `exdraw start`.
Exit 4: open http://127.0.0.1:3000 in a browser and retry.
Exit 2: usage error, read `exdraw <command> -h`.
