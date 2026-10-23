# Source-of-truth Homebrew cask for agterm. scripts/release.sh seeds this into
# umputun/homebrew-apps (Casks/agterm.rb) on first publish and rewrites the
# version + sha256 lines on every release.
cask "agterm" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/umputun/agterm/releases/download/v#{version}/agterm-#{version}.dmg"
  name "agterm"
  desc "Terminal on libghostty with a workspace/session sidebar"
  homepage "https://github.com/umputun/agterm"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "agterm.app"
  binary "#{appdir}/agterm.app/Contents/MacOS/agtermctl", target: "agtermctl"

  # strip Homebrew's com.apple.quarantine so brew install/upgrade opens with no
  # "downloaded from the internet" prompt. the app is Developer ID signed, notarized,
  # and stapled, but that only removes the unidentified-developer block and the online
  # check - Gatekeeper still shows the first-launch confirm whenever the quarantine attr
  # is present, and brew re-stamps it on every fresh bundle. the strip runs on the staged copy
  # before the move: brew's install-steps worker does not inherit the terminal's TCC grants, and
  # macOS can refuse it on the bundle in appdir. a failure only costs that prompt, so it warns.
  preflight_steps do
    run "/bin/sh",
        args: [
          "-c",
          'err=$(/usr/bin/xattr -dr com.apple.quarantine "$1" 2>&1 >/dev/null) || ' \
          'echo "Warning: could not remove quarantine from $1 ($(printf "%s\n" "$err" | head -n 1)); ' \
          'macOS may ask to confirm the first launch" >&2',
          "sh",
          "{{staged_path}}/agterm.app",
        ]
  end

  zap trash: [
    "~/Library/Application Support/agterm",
    "~/Library/Preferences/com.umputun.agterm.plist",
    "~/Library/Saved Application State/com.umputun.agterm.savedState",
  ]
end
