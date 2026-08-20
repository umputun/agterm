---
worth: later
where: agterm/Info.plist:37
added: 2026-08-20
---
# Info.plist declares no usage string for the protected folders

The sixteen `NSxxxUsageDescription` strings cover the entitlement-gated services and none of the
Files & Folders family. macOS defines an optional string per protected folder —
`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
`NSDownloadsFolderUsageDescription`, `NSNetworkVolumesUsageDescription`,
`NSRemovableVolumesUsageDescription` — and with none present it falls back to its own copy, measured in
`TCC.framework/Versions/A/Resources/Localizable.loctable` as
`REQUEST_ACCESS_SERVICE_kTCCServiceSystemPolicyDownloadsFolder` = `“%@” would like to access
files in your Downloads folder.` So the user is asked why agterm wants his Downloads and told nothing.

Every other family already explains hosted-CLI responsibility in its string, so the same pattern applies:
"Command-line tools you run inside agterm may request access to your Downloads folder through agterm."
WezTerm ships two of these written for exactly that case; Ghostty, kitty and iTerm2 ship none.

Deferred because it fixes nothing. The strings are not a gate — agterm can obtain these grants today
without them — so this repairs no denial and adds no access, and the only change is five pieces of prompt
copy. It also cannot be proven by CI, which pins the entitlement set and asserts nothing about
`Info.plist`: confirming the custom text actually renders needs a signed build and a fresh TCC state by
hand. Surfaced investigating #468, where the missing strings turned out not to be the cause.
