#!/usr/bin/env python3
"""
agtermctl-receiver — the Mac-side half of the container-overlays recipe.

Listens on a local port and runs the real `agtermctl` with whatever argv a
container-side wrapper sends, streaming its output back. One connection per
agtermctl call; a call held open by `--block` holds its connection for as
long as the overlay runs, so nothing here times a subprocess.

Protocol, one JSON object per line:
  request:  {"argv": ["session", ...], "env": {"AGTERM_*": "..."}}
  reply:    {"t": "out"|"err", "b": "<base64 chunk>"} ... {"t": "rc", "rc": N}

Only AGTERM_* names from the request environment are honored — the wrapper
sends the session identity so the call targets the container's own session.
Everything else about the child comes from this process's environment.
"""

import argparse
import base64
import json
import os
import shutil
import socketserver
import subprocess
import sys
import threading

MAX_REQUEST_BYTES = 1024 * 1024
CONNECT_TIMEOUT = 30
# The only names a request may set: the session identity the wrapper
# forwards. Anything else — a state dir, a socket path — would let a caller
# retarget this receiver's CLI at another agterm instance.
FORWARDED_ENV = {
    "AGTERM_SESSION_ID", "AGTERM_WINDOW_ID", "AGTERM_WORKSPACE_ID",
    "AGTERM_PANE", "AGTERM_PANE_ID",
}


def frame_bytes(kind, data):
    return (json.dumps({"t": kind, "b": base64.b64encode(data).decode()}) + "\n").encode()


def frame_rc(code):
    return (json.dumps({"t": "rc", "rc": code}) + "\n").encode()


class Receiver(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler, agtermctl, log):
        super().__init__(address, handler)
        self.agtermctl = agtermctl
        self.log = log


class Handler(socketserver.StreamRequestHandler):
    timeout = CONNECT_TIMEOUT

    def handle(self):
        line = self.rfile.readline(MAX_REQUEST_BYTES)
        if not line:
            return
        try:
            request = json.loads(line)
            argv = request["argv"]
            env = request.get("env") or {}
            if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
                raise TypeError("argv must be a non-empty list of strings")
            if not isinstance(env, dict) or not all(
                isinstance(k, str) and isinstance(v, str) for k, v in env.items()
            ):
                raise TypeError("env must be an object with string values")
        except (ValueError, KeyError, TypeError) as e:
            self.wfile.write(frame_rc(2))
            self.server.log(f"bad request from {self.client_address[0]}: {e}")
            return
        # only session-identity names cross the wire; the rest is this
        # process's own environment
        child_env = dict(os.environ)
        child_env.update({k: v for k, v in env.items() if k in FORWARDED_ENV})
        self.server.log(" ".join(argv))
        code = self.run([self.server.agtermctl] + argv, child_env)
        self.wfile.write(frame_rc(code))

    def run(self, argv, env):
        lock = threading.Lock()

        def send(data):
            with lock:
                self.wfile.write(data)
                self.wfile.flush()

        proc = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def pump(stream, kind):
            while True:
                chunk = stream.read1(65536)
                if not chunk:
                    return
                send(frame_bytes(kind, chunk))

        threads = [threading.Thread(target=pump, args=(proc.stdout, "out"), daemon=True),
                   threading.Thread(target=pump, args=(proc.stderr, "err"), daemon=True)]
        for t in threads:
            t.start()
        code = proc.wait()
        for t in threads:
            t.join()
        return code


def main():
    parser = argparse.ArgumentParser(description="run agtermctl for container-side wrappers")
    parser.add_argument("--port", type=int, default=59998, help="port to listen on (default 59998)")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="address to bind (default 127.0.0.1; containers reach it via host.docker.internal)")
    parser.add_argument("--agtermctl", default=None,
                        help="path to the real agtermctl (default: first agtermctl on PATH)")
    args = parser.parse_args()

    agtermctl = args.agtermctl or shutil.which("agtermctl")
    if not agtermctl:
        sys.exit("agtermctl-receiver: no agtermctl on PATH; pass --agtermctl /path/to/agtermctl")

    def log(msg):
        print(f"agtermctl-receiver: {msg}", file=sys.stderr, flush=True)

    receiver = Receiver((args.bind, args.port), Handler, agtermctl, log)
    log(f"serving {agtermctl} on {args.bind}:{args.port}")
    try:
        receiver.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
