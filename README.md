# Seeker Orb — homing projectile ability (Roblox / Luau)

A single, self-contained, **server-authoritative** homing-projectile ability written in Luau.
Equip the **Seeker Orb** tool and click: a glowing orb launches from your character,
locks onto the nearest enemy inside a forward cone, curves toward it with a bounded
turn rate, and detonates on contact.

**The code:** [`SeekerOrb.luau`](SeekerOrb.luau)

## What it demonstrates
- **Metatable-based OOP** — each orb in flight is a `Projectile` object.
- **CFrame / vector math** — `CFrame.lookAt` to orient the orb, and
  `CFrame.fromAxisAngle` (built from cross/dot products) for the steering rotation.
- **Frame-rate-independent physics** — velocity integration with acceleration, a
  max-speed clamp, and a turn rate scaled by delta-time.
- **Swept raycast** — a ray across each frame's travel segment so a fast orb can
  never tunnel through a thin wall or target.
- **Efficiency** — one shared `Heartbeat` loop drives every live orb, and orb parts
  are recycled through a pool instead of being re-created each shot.

## How to run
1. Put `SeekerOrb.luau` in **ServerScriptService** as a `Script`.
2. Press Play. The script spawns its own training dummies (no imported models needed).
3. Equip the **Seeker Orb** tool (press `1`) and click to fire.

All behaviour is tunable from the `CONFIG` table at the top of the file.
