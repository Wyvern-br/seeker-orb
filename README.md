# Seeker Orb — Homing Projectile Ability (Roblox / Luau)

A server-side homing projectile ability written in Luau.

Equip the **Seeker Orb** tool and click to launch a glowing orb. It finds the closest enemy in front of the player, smoothly turns toward the target, and explodes on impact.

**Code:** [`SeekerOrb.luau`](SeekerOrb.luau)

## Features

* Projectile system built with metatable-based OOP.
* Uses `CFrame` and vector math for movement and steering.
* Frame-rate-independent movement with acceleration, max speed, and turn-rate limits.
* Swept raycasts to prevent the projectile from passing through walls or targets.
* A single `Heartbeat` loop updates every active projectile.
* Object pooling to reuse orb parts instead of creating new ones every shot.

## Running the project

1. Place `SeekerOrb.luau` inside **ServerScriptService** as a `Script`.
2. Press **Play**.
3. The script automatically spawns a few training dummies.
4. Equip the **Seeker Orb** tool (press `1`) and click to fire.

Most of the ability's behavior can be tweaked through the `CONFIG` table at the top of the script.
