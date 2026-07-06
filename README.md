# Seeker Orb

A homing projectile ability I wrote in Luau for my Roblox combat game. You equip
the orb, click, and it flies out and chases down the nearest dummy in front of you,
curving to follow it instead of just pointing straight at it.

The part I cared most about is that it's all decided on the server. The client only
says "I clicked" — targeting, movement and damage all happen server-side, because an
ability that trusts the client is trivial to cheat.

The whole thing is one script: [`SeekerOrb.luau`](SeekerOrb.luau)

## A few things worth pointing out

- Each orb is its own object (a small `Projectile` class built on a metatable), but
  they don't each run a loop — a single `Heartbeat` connection steps all the live
  orbs. Spawning a loop per projectile gets expensive quickly.
- The homing isn't "rotate straight to the target". Every frame it turns the current
  heading toward the target by a capped amount, using `CFrame.fromAxisAngle` around
  the cross product of the two directions. Raise the cap and it snaps; lower it and
  it makes wide arcs.
- Hits are done with a raycast across the segment the orb moved that frame, not by
  checking its position. Otherwise a fast orb can be in front of a thin wall one
  frame and behind it the next without ever registering a touch.
- Orb parts are reused from a pool instead of being created and destroyed each shot.

## Running it

Put `SeekerOrb.luau` in `ServerScriptService` as a `Script` and hit Play. It spawns
its own training dummies, so there's nothing else to wire up — press `1` to equip the
tool, then click. Speed, turn rate, damage and cone angle all live in the `CONFIG`
table at the top if you want to mess with them.
