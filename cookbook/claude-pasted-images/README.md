# Claude Code pasted images

Draw an image you pasted into Claude Code under the prompt that carried it, instead of only `[Image #N]`.

## What it does

Claude Code shows a pasted screenshot in its transcript as a `[Image #N]` placeholder, so scrolling back
tells you an image was there but not which one. This recipe is a Claude Code mod that draws each pasted
image as a picture right under your prompt, sized to the terminal, using the kitty graphics protocol that
agterm's terminal engine speaks.

## Requirements

agterm 0.3.1 or later. The recipe calls no `agtermctl` command; it needs only the terminal engine, and every
release embeds a libghostty that answers the XTVERSION query as `ghostty` and draws kitty graphics.

Claude Code 2.1.312 or later, the release the mod was tested on. Mods arrived in 2.1.287; the releases in
between are untested.

## Setup

1. From the `cookbook` directory of an agterm checkout, copy this recipe's folder, including the hidden
   `.claude-plugin` directory, to where you keep mods:

   ```sh
   mkdir -p ~/.claude/mods
   cp -R claude-pasted-images ~/.claude/mods/pasted-images
   ```

2. Point Claude Code at it in the `env` block of `~/.claude/settings.json`:

   ```json
   "env": {
     "CLAUDE_CODE_PLUGIN_DIRS": "~/.claude/mods/pasted-images"
   }
   ```

   The value is the mod's own folder, not its parent. If the variable already lists other folders, append
   this one after a `:`. Claude Code reads it only from the user settings file or the process environment,
   never from a project's settings.

3. Start a new Claude Code session.

`.claude-plugin/plugin.json` names the mod and `hooks/hooks.json` lists its module, `hooks/register.tsx`.
Claude Code compiles the TypeScript itself; there is no build step. On load it also writes type
declarations into `.claude-plugin/types/`, which you can ignore.

## Usage

Paste an image into the prompt as usual (ctrl+v) and send it. The picture appears under your message in
the transcript, and stays there as you scroll. Claude Code's own `[Image #N]` link still opens the file in
your default viewer on cmd+click.

## How it works

Claude Code saves every pasted image as `<tmp>/claude-<uid>/<project>/<session id>/images/<N>.png`, where
`<tmp>` is `CLAUDE_CODE_TMPDIR` or `/tmp`, and `<project>` is the session's root directory with every
character other than a letter or digit replaced by `-`. The mod hooks the drawing of your own prompt rows,
finds each `[Image #N]` in the text, reads the matching file's PNG header for its size, and adds a mod-API
`Image` element below the row that points at the file.

The session id is read at every draw, not once at startup: `/clear` continues under a new session id
without a new session start, and an id captured at startup would look in the previous conversation's
folder and could show its image under a new prompt with the same number.

Claude Code draws a mod's `Image` through the kitty graphics protocol only after the terminal identifies
itself. It asks with XTVERSION and a kitty graphics query; agterm's libghostty answers XTVERSION with
`ghostty <version>`, which Claude Code accepts.

The box is at most 80 columns wide and 30 rows tall, and never more than half the window's height. Its
height comes from the image's aspect ratio, assuming a cell twice as tall as it is wide.

## Limits

The mod reads only files under Claude Code's temp folder and changes nothing on disk.

The folder layout and the project-name rule are what Claude Code does today, not a documented interface.
If a Claude Code release changes either, the mod quietly draws nothing, since a missing file is skipped
rather than shown as an empty box. A very long project path may be named differently there; that case is
untested.

Only PNG pastes up to 4 MiB are drawn, the most a mod may read in one call. Larger images and other
formats keep the plain placeholder.

The picture is passed to the terminal as a file path, so the terminal has to read the same disk Claude
Code writes. In a session attached to another Mac, and inside tmux, you see the placeholder text.

Images in a resumed conversation show only while their files still exist under the current session's
folder, and the temp folder may be cleared on reboot.

With a font whose cells are far from 2:1, pictures look slightly stretched.
