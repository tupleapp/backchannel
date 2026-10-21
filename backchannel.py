#!/usr/bin/env python3
"""Backchannel: start an Amp thread for every Tuple call, automatically.

Runs forever (installed as a LaunchAgent by ./install). Every few seconds it
checks the dev, staging and production Tuple apps. When one is in a call it
starts `amp -x --stream-json-input` in this repo and feeds the thread:

- the call transcript, from `tuple capture follow`, batched and de-noised
- muted asides, card feedback and card action clicks from the Backchannel app

When the call ends it tells the thread, closes its input and lets it finish.
If this process restarts mid-call, it continues the same thread.
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.realpath(__file__))
TUPLE = os.environ.get("TUPLE_BIN", "/usr/local/bin/tuple")
AMP = os.environ.get("AMP_BIN", "/opt/homebrew/bin/amp")
APP_DIR = os.path.expanduser("~/Library/Application Support/Backchannel")
LOG_DIR = os.path.expanduser("~/Library/Logs/Backchannel")
ROOM = os.environ.get("BACKCHANNEL_ROOM", "#backchannel")  # Slack channel the call's agents share
SESSIONS = os.path.join(APP_DIR, "sessions.json")

# Same preference order as the Backchannel app: dev, then staging, then production.
TARGETS = [
    ("dev", "/tmp/tuple.dev.sock"),
    ("staging", "/tmp/tuple.staging.sock"),
    ("prod", "/tmp/tuple.sock"),
]
POLL = 5  # seconds between state checks while Tuple's triggers have never woken us
TRIGGERED_POLL = 30  # once triggers work, they wake us; this is only a safety net
# Tuple runs ./trigger from these on call-connected, room-joined and call-ended (installed by ./install).
TRIGGER_DIRS = [os.path.expanduser(f"~/{d}/triggers/backchannel") for d in (".tuple", ".tuplestaging", ".tupledev")]
END_GRACE = 15  # seconds out of the call before we call it over
FLUSH = 2  # seconds of quiet before a transcript batch is sent

NOISE = re.compile(
    r"stream_opened|caught_up|stroke_(started|ended)|annotations_cleared|canvas_reset|highlighted"
    r"|webcam_(started|stopped)|text_started"
    r"|: (Mm-hmm|Mmm|Hmm|Yeah|Yep|Yes|No|Okay|OK|Ok|Thank you|Thanks|Uh-huh|Uh|Um|Right|Oh|Sure|Nice|Cool|Great|you|-)[.,!?]*$"
)


def log(msg):
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def tuple_args(env, host):
    return [TUPLE, "-H", host, "--env", env]


def state(env, host):
    if not os.path.exists(host):
        return None
    try:
        out = subprocess.run(
            tuple_args(env, host) + ["--format", "json", "state"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return json.loads(out)
    except Exception:
        return None


def call_id_of(st):
    call = (st or {}).get("call") or {}
    return call.get("id") or call.get("call_id")


def load_sessions():
    try:
        with open(SESSIONS) as f:
            return json.load(f)
    except Exception:
        return {}


def save_sessions(sessions):
    os.makedirs(APP_DIR, exist_ok=True)
    tmp = SESSIONS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(sessions, f, indent=1)
    os.replace(tmp, SESSIONS)


class Session:
    """One Amp thread following one Tuple call."""

    def __init__(self, env, host, call_id, st, record):
        self.env, self.host, self.call_id = env, host, call_id
        self.state = st
        self.record = record  # persisted: thread id, last flush time
        self.lock = threading.Lock()
        self.pending = []
        self.closed = False
        self.follow = None
        self.amp = None
        self.last_line = 0

    # -- Amp side ---------------------------------------------------------

    def start(self):
        os.makedirs(LOG_DIR, exist_ok=True)
        stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
        self.log_path = os.path.join(LOG_DIR, f"{stamp}-{self.call_id[:8]}.jsonl")
        thread = self.record.get("thread")
        common = [
            "-x", "--stream-json", "--stream-json-input",
            "--settings-file", os.path.join(REPO, "settings.json"),
            "--plugin-ready-timeout", "30",
        ]
        if thread:
            args = [AMP, "threads", "continue", thread] + common
        else:
            args = [AMP] + common + [
                "--visibility", "private",
                "--no-archive-after-execute",
                "--title", self.title(),
                "-l", "backchannel",
            ]
        env = dict(os.environ, TUPLE_HOST=self.host, TUPLE_ENV=self.env, BACKCHANNEL_CALL_ID=self.call_id)
        self.amp = subprocess.Popen(
            args, cwd=REPO, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        threading.Thread(target=self.read_amp, daemon=True).start()
        self.send(self.intro(resumed=bool(thread)))
        self.start_follow()
        for name, tag in (("asides.jsonl", "aside"), ("card-feedback.jsonl", "feedback"),
                          ("card-actions.jsonl", "action")):
            threading.Thread(target=self.tail, args=(name, tag), daemon=True).start()
        threading.Thread(target=self.flusher, daemon=True).start()

    def title(self):
        people = [p.get("full_name") or p.get("name") for p in self.participants()]
        people = [p for p in people if p]
        who = ", ".join(people[:4]) if people else self.call_id[:8]
        return f"Backchannel · {datetime.now():%Y-%m-%d %H:%M} · {who}"

    def participants(self):
        call = (self.state or {}).get("call") or {}
        return call.get("participants") or call.get("peers") or []

    def intro(self, resumed):
        flags = f"-H {self.host} --env {self.env}"
        head = (
            "The Backchannel service restarted; you are continuing this call. Earlier lines may repeat.\n\n"
            if resumed else
            "You are Backchannel for this Tuple call. Follow AGENTS.md.\n\n"
        )
        return (
            head
            + f"Environment: {self.env}. Call ID: {self.call_id}. "
            + f"Tuple CLI for this call: `tuple {flags} …`. Back room: Slack {ROOM}.\n"
            + "Call state when the call was detected:\n```json\n"
            + json.dumps((self.state or {}).get("call"), indent=1)[:4000]
            + "\n```\nTranscript batches follow as messages tagged [transcript].\n\n"
            + "Tuple's own connect prompt for this call follows. This service already supplies the call "
            + "(delivery option 1 in Tuple's live-call guide), so don't start your own follower.\n\n"
            + self.connect_prompt()
        )

    def connect_prompt(self):
        try:
            return subprocess.run(tuple_args(self.env, self.host) + ["connect", "prompt", "--call", self.call_id],
                                  capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception as e:
            return f"(tuple connect prompt failed: {e})"

    def read_amp(self):
        with open(self.log_path, "a") as f:
            for line in self.amp.stdout:
                f.write(line)
                f.flush()
                if '"subtype":"init"' in line and not self.record.get("thread"):
                    try:
                        tid = json.loads(line)["session_id"]
                    except Exception:
                        continue
                    self.record["thread"] = tid
                    log(f"call {self.call_id} -> https://ampcode.com/threads/{tid}")

    def send(self, text):
        msg = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
        with self.lock:
            if self.closed or self.amp.poll() is not None:
                return
            try:
                self.amp.stdin.write(json.dumps(msg) + "\n")
                self.amp.stdin.flush()
                self.record["last_sent"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
            except BrokenPipeError:
                pass

    # -- Tuple side -------------------------------------------------------

    def start_follow(self):
        args = tuple_args(self.env, self.host) + [
            "capture", "follow", self.call_id,
            "--exclude", "content", "--timestamps", "clock", "--batch", "20s",
            "--wake-on", "Amp", "--wake-on", "Backchannel",
        ]
        since = self.record.get("last_sent")
        if since:
            args += ["--since", since]
        self.follow = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       text=True, bufsize=1)
        threading.Thread(target=self.read_follow, daemon=True).start()

    def read_follow(self):
        for line in self.follow.stdout:
            line = line.rstrip()
            if line and not NOISE.search(line):
                with self.lock:
                    self.pending.append(line)
                    self.last_line = time.time()

    def flusher(self):
        while not self.closed:
            time.sleep(0.5)
            with self.lock:
                ready = self.pending and time.time() - self.last_line >= FLUSH
                batch, self.pending = (self.pending, []) if ready else ([], self.pending)
            if batch:
                self.send("[transcript]\n" + "\n".join(batch))

    def tail(self, name, tag):
        path = os.path.join(APP_DIR, name)
        pos = os.path.getsize(path) if os.path.exists(path) else 0
        while not self.closed:
            time.sleep(1)
            if not os.path.exists(path):
                continue
            size = os.path.getsize(path)
            if size < pos:
                pos = 0
            if size == pos:
                continue
            with open(path) as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            lines = [l for l in chunk.splitlines() if l.strip()]
            if lines:
                self.send(f"[{tag}]\n" + "\n".join(lines))

    # -- End --------------------------------------------------------------

    def finish(self):
        with self.lock:
            batch, self.pending = self.pending, []
        if batch:
            self.send("[transcript]\n" + "\n".join(batch))
        self.send("[call-ended] The call has ended. Finish the call's Obsidian page (status: ended) "
                  "and any People pages now. You'll get no more messages after this.")
        with self.lock:
            self.closed = True
            try:
                self.amp.stdin.close()
            except Exception:
                pass
        if self.follow and self.follow.poll() is None:
            self.follow.terminate()
        try:
            self.amp.wait(timeout=30 * 60)
        except subprocess.TimeoutExpired:
            self.amp.terminate()
        log(f"call {self.call_id} finished (amp exit {self.amp.returncode})")

    def alive(self):
        return self.amp is not None and self.amp.poll() is None


def main():
    log(f"backchannel started (repo {REPO})")
    sessions = load_sessions()
    active = {}  # call_id -> Session
    last_seen = {}
    while True:
        now = time.time()
        in_call = {}
        for env, host in TARGETS:
            st = state(env, host)
            if st and st.get("in_call"):
                cid = call_id_of(st)
                if cid:
                    in_call[cid] = (env, host, st)

        for cid, (env, host, st) in in_call.items():
            last_seen[cid] = now
            s = active.get(cid)
            if s and s.alive():
                continue
            rec = sessions.setdefault(cid, {"env": env})
            rec.pop("ended", None)  # rejoined a call we'd seen end: continue its thread
            rec["starts"] = rec.get("starts", 0) + 1
            if rec["starts"] > 5:
                if rec["starts"] == 6:
                    log(f"call {cid}: amp keeps exiting, giving up on this call (see {LOG_DIR})")
                continue
            if s:  # the Amp process died mid-call; continue the same thread
                log(f"call {cid}: amp exited mid-call, continuing thread")
                s.closed = True
                if s.follow and s.follow.poll() is None:
                    s.follow.terminate()
            log(f"call {cid} on {env}: starting session")
            s = Session(env, host, cid, st, rec)
            try:
                s.start()
            except Exception as e:
                log(f"call {cid}: failed to start: {e}")
                continue
            active[cid] = s
            save_sessions(sessions)

        for cid in list(active):
            if cid not in in_call and now - last_seen.get(cid, 0) > END_GRACE:
                s = active.pop(cid)
                sessions[cid]["ended"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
                save_sessions(sessions)
                threading.Thread(target=s.finish, daemon=True).start()

        save_sessions(sessions)
        wait_for_wake()


def wake_stamps():
    stamps = []
    for d in TRIGGER_DIRS:
        try:
            stamps.append(os.path.getmtime(os.path.join(d, "wake")))
        except OSError:
            pass
    return stamps


def wait_for_wake():
    """Sleep until a Tuple trigger touches a wake file, or the poll interval passes."""
    before = wake_stamps()
    deadline = time.time() + (TRIGGERED_POLL if before else POLL)
    while time.time() < deadline:
        time.sleep(0.5)
        if wake_stamps() != before:
            return


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
