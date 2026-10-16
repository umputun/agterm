---
worth: maybe
where: agtermCore/Sources/agtermCore/AppStore+Persistence.swift:saveChecked
added: 2026-10-14
---
# a failed window snapshot save is invisible

`AppStore.saveChecked` logs a failed `windows/<id>.json` write through `AppStore.log`, which is `NSLog`,
and nothing else sees it. The index has `WindowLibrary.indexUnsaved` reported in the tree; a window
snapshot has no equivalent, so a window whose saves keep failing looks healthy until a relaunch restores
the last file that landed. A `subsystem == "com.umputun.agterm"` log query also misses `NSLog` output.

Surfaced investigating #741, where sessions created in the last ~2.5 hours before quit were missing from
the restored tree. A frozen snapshot fits the report, but nothing on the reporter's side could confirm it.
Open design question: a tree flag like `indexUnsaved`, an `os.Logger` entry, or both.
