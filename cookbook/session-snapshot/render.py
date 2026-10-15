#!/usr/bin/env python3
"""Render a snapshot.sh work dir into <stamp>.json and <stamp>.html. Called by snapshot.sh."""
import collections
import datetime
import glob
import json
import os
import re
import shlex
import sys

work, out, stamp, restore_bin = sys.argv[1:5]
home = os.path.expanduser("~")
UUID = re.compile(r"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
SHELLS = {"zsh", "bash", "fish", "sh", "login"}
MAX_TURNS = int(os.environ.get("AGT_SNAP_TURNS", "200"))  # 0 keeps conversation text out of the snapshot
MAX_TEXT = 6000


def tilde(p):
    return "~" + p[len(home):] if p and p.startswith(home) else (p or "")


def prog(argv):
    return os.path.basename(argv[0]).lstrip("-") if argv else ""


def clip(t):
    return t if len(t) <= MAX_TEXT else t[:MAX_TEXT] + f"\n… [{len(t) - MAX_TEXT} more characters]"


def mtime(path):
    return datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone().strftime("%Y-%m-%d %H:%M")


LIVE = "running claude process"
CMDLINE = "claude command line"
WRAPPER = "transcript named after the agterm session (per-tab wrapper)"

# (agterm session id, AGTERM_PANE, AGTERM_PANE_ID, conversation id) per live Claude process
live = []
with open(f"{work}/claude.tsv") as f:
    for line in f:
        a, pane, pane_id, s = line.rstrip("\n").split("\t")
        live.append((a.upper(), pane, pane_id.upper(), s.lower()))


def live_conversation(sess, role):
    """The conversation a live Claude runs in this session's `role` pane, left or right. AGTERM_PANE is baked at
    spawn and goes stale when a split is promoted, so the pane id read back from `surfaces` wins when present."""
    kinds = {x["paneID"].upper(): x.get("kind") for x in sess.get("surfaces") or [] if x.get("paneID")}
    for a, pane, pane_id, sid in live:
        if a == sess["id"].upper() and kinds.get(pane_id, pane) == role:
            return sid
    return None


def blocks(o):
    c = (o.get("message") or {}).get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [x for x in c if isinstance(x, dict)] if isinstance(c, list) else []


def text_of(o):
    return "\n".join(b.get("text", "") for b in blocks(o) if b.get("type") == "text").strip()


def transcript(sid):
    m = glob.glob(f"{home}/.claude/projects/*/{sid.lower()}.jsonl") if sid else []
    if not m:
        return None
    info = {"sid": sid.lower(), "path": tilde(m[0]), "size": os.path.getsize(m[0]), "cwd": None, "branch": None,
            "model": None, "version": None, "started": None, "title": None, "prompts": 0, "replies": 0}
    custom, tools, turns = None, collections.Counter(), []
    with open(m[0], errors="replace") as f:
        for line in f:
            if '"type"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            t, ts = o.get("type"), o.get("timestamp")
            if t == "custom-title":
                custom = o.get("customTitle") or custom
            elif t == "ai-title":
                info["title"] = o.get("aiTitle") or info["title"]
            if t not in ("user", "assistant") or o.get("isMeta") or o.get("isSidechain"):
                continue
            info["started"] = info["started"] or ts
            info["cwd"] = info["cwd"] or o.get("cwd")
            info["branch"] = o.get("gitBranch") or info["branch"]
            info["version"] = o.get("version") or info["version"]
            text = text_of(o)
            if t == "assistant":
                info["model"] = (o.get("message") or {}).get("model") or info["model"]
                for b in blocks(o):
                    if b.get("type") == "tool_use":
                        tools[b.get("name") or "?"] += 1
                if text:
                    info["replies"] += 1
                    turns.append({"role": "assistant", "ts": ts, "text": clip(text)})
            elif text and not text.startswith("<"):
                info["prompts"] += 1
                turns.append({"role": "user", "ts": ts, "text": clip(text)})
    info["title"] = custom or info["title"]
    info["modified"] = mtime(m[0])
    info["tools"] = tools.most_common()
    info["omitted"] = max(0, len(turns) - MAX_TURNS)
    info["turns"] = turns[-MAX_TURNS:] if MAX_TURNS > 0 else []
    prompts = [x["text"] for x in turns if x["role"] == "user"]
    info["first"], info["last"] = (prompts[0], prompts[-1]) if prompts and MAX_TURNS > 0 else (None, None)
    return info


def conversation(sess, role, fg):
    """The conversation in the session's `role` pane and how it was matched, or (None, None)."""
    found = []
    sid = live_conversation(sess, role)
    if sid:
        found.append((sid, LIVE))
    if prog(fg) == "claude":
        for i, a in enumerate(fg[:-1]):
            if a in ("-r", "--resume", "--session-id") and UUID.match(fg[i + 1]):
                found.append((fg[i + 1], CMDLINE))
    if role == "left":
        found.append((sess["id"], WRAPPER))
    for sid, how in found:
        t = transcript(sid)
        if t:
            return t, how
    return None, None


def candidates(cwd, n=5):
    """Recent conversations started in cwd, for a session no conversation could be matched to."""
    d = f"{home}/.claude/projects/{re.sub(r'[^A-Za-z0-9]', '-', cwd)}"
    found = []
    for path in sorted(glob.glob(f"{d}/*.jsonl"), key=os.path.getmtime, reverse=True)[:n]:
        title, custom, first = None, None, None
        with open(path, errors="replace") as f:
            for line in f:
                if not ('"custom-title"' in line or '"ai-title"' in line or (first is None and '"type":"user"' in line)):
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                t = o.get("type")
                if t == "custom-title":
                    custom = o.get("customTitle") or custom
                elif t == "ai-title":
                    title = o.get("aiTitle") or title
                elif t == "user" and not o.get("isMeta"):
                    txt = text_of(o)
                    if txt and not txt.startswith("<"):
                        first = clip(txt[:300]) if MAX_TURNS > 0 else None
        sid = os.path.basename(path)[:-6]
        found.append({"sid": sid, "title": custom or title, "modified": mtime(path), "first": first,
                      "resume": f"cd {shlex.quote(cwd)} && claude --resume {sid}"})
    return found


def running(fg):
    """Whether fg is a program to replay rather than an idle shell. A shell running a script or -c is a program."""
    p = prog(fg)
    if not p or p == "login":
        return False
    return p not in SHELLS or any(a == "-c" or not a.startswith("-") for a in fg[1:])


def restore_line(conv, matched, fg, here, start):
    """What restore.sh types into a new pane whose shell opens in `start`: claude --resume when a conversation was
    found in the pane (a live Claude may sit under a wrapper such as caffeinate), else the program it ran, else
    nothing. A transcript named after the session only counts when no other program holds the pane."""
    line, target = None, here
    if conv and (matched in (LIVE, CMDLINE) or not running(fg)):
        line, target = f"claude --resume {conv['sid']}", conv["cwd"] or here
    elif running(fg):
        line = shlex.join(fg)
    if target != start:
        line = f"cd {shlex.quote(target)}" + (f" && {line}" if line else "")
    return line


snap_path = os.path.abspath(f"{out}/{stamp}.json")
snap = {"stamp": stamp, "created": datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M"), "file": tilde(snap_path),
        "windows": [], "sessions": []}
with open(f"{work}/windows.json") as f:
    windows = json.load(f)["result"]["windows"]
for w in windows:
    path = f"{work}/tree-{w['id']}.json"
    if not os.path.exists(path):
        continue
    with open(path) as f:
        tree = json.load(f)["result"]["tree"]
    win = {"id": w["id"], "name": w.get("name") or "window", "workspaces": []}
    for ws in tree.get("workspaces", []):
        wsn = {"id": ws["id"], "name": ws.get("name", ""), "sessions": [],
               "snippet": shlex.join([restore_bin, snap_path, "--workspace", ws["id"]])}
        for s in ws.get("sessions", []):
            fg, cwd = s.get("foreground") or [], s.get("cwd") or home
            conv, matched = conversation(s, "left", fg)
            split = None
            if s.get("hasSplit") or s.get("split"):
                sfg, scwd = s.get("splitForeground") or [], s.get("splitCwd") or cwd
                sconv, smatched = conversation(s, "right", sfg)
                split = {"cwd": scwd, "foreground": sfg, "matched": smatched,
                         "claude": sconv and {k: sconv[k] for k in ("sid", "title", "cwd")},
                         "restore": restore_line(sconv, smatched, sfg, scwd, cwd)}
            try:
                with open(f"{work}/screen-{s['id']}.txt", errors="replace") as f:
                    screen = f.read().rstrip()
            except OSError:
                screen = ""
            rec = {"id": s["id"], "name": s.get("name", ""), "title": s.get("title"), "workspace": wsn["name"],
                   "workspaceId": ws["id"], "window": win["name"], "cwd": cwd, "foreground": fg,
                   "flagged": bool(s.get("flagged")), "status": s.get("status"), "claude": conv,
                   "restore": restore_line(conv, matched, fg, cwd, cwd), "split": split, "screen": screen, "matched": matched,
                   "resume": conv and f"cd {shlex.quote(conv['cwd'] or cwd)} && claude --resume {conv['sid']}",
                   "candidates": [] if conv else candidates(cwd),
                   "snippet": shlex.join([restore_bin, snap_path, s["id"]])}
            snap["sessions"].append(rec)
            wsn["sessions"].append(rec["id"])
        win["workspaces"].append(wsn)
    snap["windows"].append(win)

by_conv = collections.defaultdict(list)
for s in snap["sessions"]:
    label = f"{s['workspace']} / {s['name']}"
    for c, where in ((s["claude"], label), (s["split"] and s["split"]["claude"], f"{label} (split)")):
        if c:
            by_conv[c["sid"]].append((s, where))
for group in by_conv.values():
    for s, where in group:
        s.setdefault("sharedWith", []).extend(w for o, w in group if not (o is s and w == where))

with open(snap_path, "w") as f:
    json.dump(snap, f, indent=1, ensure_ascii=False)

# escaped so nothing in a command line or a conversation can close the <script> it is embedded in
data = json.dumps(snap, ensure_ascii=False)
for ch, esc in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), (" ", "\\u2028"), (" ", "\\u2029")):
    data = data.replace(ch, esc)
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "page.html")) as f:
    page = f.read()
hpath = f"{out}/{stamp}.html"
with open(hpath, "w") as f:
    f.write(page.replace("/*__SNAPSHOT__*/null", data, 1))
latest = f"{out}/latest.html"
if os.path.lexists(latest):
    os.remove(latest)
os.symlink(os.path.basename(hpath), latest)
print(hpath)
