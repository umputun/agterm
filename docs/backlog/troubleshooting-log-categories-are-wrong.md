---
worth: now
where: docs/troubleshooting.md:31
added: 2026-08-15
---
# The documented log categories list one that does not exist and omits three that do

`docs/troubleshooting.md:31` tells users the categories are `CustomCommandRunner`, `SettingsModel`,
`GhosttyApp`, `NotificationManager`, and `ControlServer`, right under a `log show` example that filters on
`subsystem == "com.umputun.agterm" && category == "<name>"`.

`ControlServer` is not one of them. `ControlServer.log` is `NSLog("agterm: %@", …)`
(`agterm/Control/ControlServer.swift:659-660`), not a `Logger(subsystem:category:)`, so it carries neither
the subsystem nor a category. A user following the page to debug the control socket - the most likely
reason to reach for these instructions at all - gets an empty result and no indication why.

The seven real categories are `GhosttyApp`, `GhosttySurfaceView`, `WatermarkRenderer`,
`NotificationManager`, `SettingsView`, `SettingsModel`, and `CustomCommandRunner`. The page names four of
them and omits `GhosttySurfaceView`, `WatermarkRenderer`, and `SettingsView`.

Two ways to close it, and they are not equivalent: correct the list to the seven that exist and drop
`ControlServer`, or convert `ControlServer.log` to a real `Logger` so the documented filter starts working.
The second is the better outcome for anyone debugging the socket, since it is currently the one subsystem
with no queryable output, but it is a behavior change rather than a doc fix.

Surfaced while investigating discussion #439 (close provenance), which asked for close logging and led
through every logging call site in the app.
