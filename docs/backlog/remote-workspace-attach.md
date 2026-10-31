---
worth: maybe
where: agtermCore/Sources/agtermCore/RemoteTree.swift:RemoteTreeMerger.candidates
added: 2026-10-30
---
# attach a whole remote workspace at once

Remote attach brings one session group at a time (`zmx.attach.group`). Attaching every group of one
remote workspace was left out when group attach was designed.

The cheap form attaches the attachable groups of remote workspace X into this window's current
workspace. It reads one `zmx tree`, picks the top-level rows by `workspaceID`, and runs the group attach
for each in source order. It creates no local workspace and keeps no link to the remote one. Reuse the
one snapshot: calling the public group command per group rereads the origin each time, and looping over
flat rows attaches companions twice. The receipt can be a flat list of group receipts.

Two parts add decisions. A new local workspace named after the remote one persists while its remote
rows never do (`AppStore+Snapshot.swift` filters them), so it comes back empty after a relaunch. And
"every omission named" needs workspace membership from the origin: `candidates` drops an unattachable
top-level session entirely, and the parent's `companions` list covers only children.
