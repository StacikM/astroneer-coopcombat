"""Local admin panel for the CoopCombat mod.

Run:  python server.py            then open http://127.0.0.1:8765
It only listens on 127.0.0.1. The mod writes state.json and reads commands.txt in DATA_DIR.
"""
import argparse
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_DATA_DIR = (
    r"C:\Program Files (x86)\Steam\steamapps\common\ASTRONEER\Astro\Binaries\Win64"
    r"\ue4ss\Mods\CoopCombat\panel"
)
HERE = os.path.dirname(os.path.abspath(__file__))

PLAYER_COMMANDS = {"hurt", "heal", "down", "revive", "kill", "explode", "give"}
SETTINGS = {
    "DAMAGE", "SNIPE_DAMAGE", "GUN_DAMAGE", "GUN_COOLDOWN", "HIT_RADIUS", "PVP_IN_CREATIVE", "BLEEDOUT_SECONDS", "CRAWL_SPEED_SCALE",
    "DOWNED_HEALTH", "REVIVE_RANGE", "REVIVE_SECONDS", "EXPLODE_COUNT",
}
ID_RE = re.compile(r"^\d{1,20}$")
STR_SETTINGS = {
    "GUN_ITEM": {"WorkLight", "FloodLight", "Beacon", "Skybreaker", "Battery"},
    "GUN_KEY": {"LMB", "RMB", "MMB", "MOUSE4", "MOUSE5"},
}


def build_command(body):
    cmd = body.get("cmd")
    if cmd == "say":
        text = body.get("text")
        if isinstance(text, str):
            text = "".join(c if c.isprintable() else " " for c in text)[:200].strip()
            if text:
                return "say " + text
        return None
    if cmd == "setstr":
        name, value = body.get("name"), body.get("value")
        if name in STR_SETTINGS and value in STR_SETTINGS[name]:
            return f"setstr {name} {value}"
        return None
    if cmd == "set":
        name, value = body.get("name"), body.get("value")
        if name in SETTINGS and isinstance(value, (int, float)) and not isinstance(value, bool):
            return f"set {name} {float(value):.4f}"
    elif cmd in PLAYER_COMMANDS:
        pid = str(body.get("id", ""))
        if not ID_RE.match(pid):
            return None
        amount = body.get("amount")
        if cmd == "hurt" and isinstance(amount, (int, float)) and not isinstance(amount, bool):
            return f"hurt {pid} {float(amount):.4f}"
        if cmd == "give":
            return f"give {pid} gun"
        if cmd != "hurt":
            return f"{cmd} {pid}"
    return None


def make_handler(data_dir):
    state_path = os.path.join(data_dir, "state.json")
    cmd_path = os.path.join(data_dir, "commands.txt")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _send(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _host_ok(self):
            return self.headers.get("Host", "").split(":")[0] in ("127.0.0.1", "localhost")

        def do_GET(self):
            if not self._host_ok():
                return self._send(403, "{}")
            if self.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            if self.path == "/api/state":
                try:
                    with open(state_path, "r", encoding="utf-8") as f:
                        state = json.load(f)
                    age = time.time() - float(state.get("time", 0))
                    state["age"] = round(age, 1)
                    state["connected"] = age < 4
                except (OSError, ValueError):
                    state = {"connected": False, "players": [], "config": {}, "age": None}
                return self._send(200, json.dumps(state))
            self._send(404, "{}")

        def do_POST(self):
            # a custom header can't be sent cross-site without a CORS preflight, which this server never grants
            if not self._host_ok() or self.headers.get("X-Panel") != "1" or self.path != "/api/cmd":
                return self._send(403, "{}")
            try:
                length = min(int(self.headers.get("Content-Length", "0")), 4096)
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return self._send(400, '{"ok":false}')
            line = build_command(body) if isinstance(body, dict) else None
            if not line:
                return self._send(400, '{"ok":false,"error":"bad command"}')
            try:
                with open(cmd_path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError as e:
                return self._send(500, json.dumps({"ok": False, "error": str(e)}))
            self._send(200, json.dumps({"ok": True, "sent": line}))

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default=DEFAULT_DATA_DIR)
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    os.makedirs(args.data_dir, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args.data_dir))
    print(f"CoopCombat panel: http://127.0.0.1:{args.port}  (data: {args.data_dir})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
