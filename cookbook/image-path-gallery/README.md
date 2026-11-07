# Image path gallery

Open the image paths printed on a pane's screen in a gallery, also when the session is attached from another Mac.

Author: [@wildsurfer](https://github.com/wildsurfer)

## What it does

An agent such as Claude Code often prints the path of a screenshot it made. In a session attached with `agtermctl zmx attach`, this file is on the other Mac, and ⌘-click does not open a bare path in an attached pane. This recipe adds one chord that finds the image paths on the screen, copies the files to this Mac when the session is attached, and shows them in an overlay with a large image and a thumbnail strip. The chord works in a local session too.

## Requirements

agterm 0.36.0 or later, where a page opened with `--js` can close its overlay with `window.close()`. The script also relies on `--chromeless` from 0.35.0, `session overlay open --html` from 0.33.0, `--error-hud` from 0.31.0 and `AGT_SESSION_HOST` from 0.29.0.

`perl`, which macOS includes. For an attached session, `ssh` and `scp` with key-based login to the host, which `zmx attach` already needs.

## Setup

1. Copy `image-path-gallery.sh` to `~/.config/agterm/scripts/` and keep it executable.
2. Add the chord to `~/.config/agterm/keymap.conf`:

   ```
   command "image path gallery" cmd+shift+i --error-hud ~/.config/agterm/scripts/image-path-gallery.sh
   ```

3. Run `agtermctl keymap reload`.

Pick another chord if cmd+shift+i is already taken in your keymap. To use a different CLI, prefix the script path in the keymap line with `AGTERMCTL=/path/to/agtermctl`.

## Usage

Press the chord when image paths are visible in the pane. To open only some of them, select them with a terminal selection first.

In the gallery, the arrow keys move between the images and wrap at the ends, and a click on a thumbnail opens that image. Esc or Enter closes the gallery.

## How it works

Claude Code draws its own mouse selection, so agterm does not see it and `$AGT_SELECTION` stays empty. For this reason the script reads the visible screen with `session text` when there is no terminal selection.

Claude Code also wraps long paths with an indent, so the script removes all whitespace before it searches. The match is non-greedy and stops at the first image extension, otherwise two neighbour paths become one.

The allowed characters in a path are also the quoting. The path goes through two shells over ssh and terminal text is not trusted, so a path with other characters is not matched.

The page reads local files only, so the script copies the images to a temp directory with `scp` and generates the page there. A number in front of each file name keeps equal names apart. `--block` keeps the script running until the page closes, and then the script removes the directory. Exit status 2 means a page closed without an answer, which is the normal way out of this page.

## Limits

Text on the screen decides which files are read. Any program in the pane can print a path, and the chord then copies that file from the host to this Mac and displays it, if it has an image extension and your ssh account can read it. Use the chord only on a pane whose output you trust.

The recipe deletes nothing on the host. The local copies are removed when the gallery closes.

Only the visible screen is read, not the scrollback. Only absolute paths ending in png, jpg, jpeg, gif or webp are matched.

A path with a space is not found. Because whitespace is removed, a path is also lost when it comes directly after another word with a slash: `src/a.txt /tmp/x.png` does not find `/tmp/x.png`.

Nothing is shown until all the images are copied, so many large files take time, and one failed copy stops the whole gallery.

The scratch pane counts as local. A local split of an attached session still looks on the host.
