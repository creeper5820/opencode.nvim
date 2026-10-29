#!/usr/bin/env python3
"""Real tmux end-to-end verification for the terminal-only plugin.

Starts an isolated Neovim (temporary HOME/XDG/project) and the official
OpenCode TUI with --standalone, drives both through a private tmux socket, and
checks that OpenCode itself receives Alt keys, leader combinations and text.
It never touches the user's Neovim configuration, tmux sessions or OpenCode
service.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback

BASE = "/tmp/opencode"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOCKET = f"opencode-e2e-{os.getpid()}"
SESSION = "e2e"
NVIM = shutil.which("nvim")
TMUX = shutil.which("tmux")
OPENCODE = shutil.which("opencode")


class Failure(AssertionError):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class E2E:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="tmux-e2e-", dir=BASE)
        self.paths = {
            name: os.path.join(self.root, name)
            for name in (
                "home", "config", "data", "state", "cache", "runtime",
                "tmp", "project",
            )
        }
        for path in self.paths.values():
            os.makedirs(path, exist_ok=True)
        os.chmod(self.paths["runtime"], 0o700)
        os.makedirs(os.path.join(self.paths["config"], "nvim"), exist_ok=True)
        with open(os.path.join(self.paths["project"], "README"), "w") as handle:
            handle.write("isolated tmux e2e project\n")
        self._write_init()
        self.port = free_port()
        self.server = f"127.0.0.1:{self.port}"
        self.started = False

    def _write_init(self):
        init = f"""
vim.opt.runtimepath:prepend({json.dumps(REPO)})
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "
vim.g.maplocalleader = " "
-- LazyVim-style global Terminal mapping.  The embedded TUI must still receive
-- literal "jk" text in Terminal mode.
vim.keymap.set("t", "jk", "<C-\\\\><C-n>", {{ noremap = true }})
-- A global Normal Alt map proves the OpenCode window does not route Normal keys.
vim.keymap.set("n", "<A-b>", "^", {{ desc = "global Alt-b" }})
require("opencode").setup({{
  args = {{ "--standalone" }},
  window = {{ layout = "right", size = 100 }},
}})
"""
        with open(os.path.join(self.paths["config"], "nvim", "init.lua"), "w") as handle:
            handle.write(init)

    def env(self):
        return {
            "HOME": self.paths["home"],
            "XDG_CONFIG_HOME": self.paths["config"],
            "XDG_DATA_HOME": self.paths["data"],
            "XDG_STATE_HOME": self.paths["state"],
            "XDG_CACHE_HOME": self.paths["cache"],
            "XDG_RUNTIME_DIR": self.paths["runtime"],
            "TMPDIR": self.paths["tmp"],
            "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
            "NVIM_APPNAME": "opencode-e2e",
        }

    def start(self):
        env = self.env()
        env_args = " ".join(f"{key}={json.dumps(value)}" for key, value in env.items())
        command = (
            f"env -i {env_args} {json.dumps(NVIM)} "
            f"--listen {self.server} --noplugin -u "
            f"{json.dumps(os.path.join(self.paths['config'], 'nvim', 'init.lua'))}"
        )
        subprocess.run(
            [
                TMUX, "-L", SOCKET, "-f", "/dev/null", "new-session", "-d",
                "-s", SESSION, "-x", "200", "-y", "55", "-c",
                self.paths["project"], command,
            ],
            check=True,
        )
        self.started = True
        self.wait_rpc("vim.api.nvim_get_mode().mode ~= nil", timeout=20)

    def stop(self):
        if not self.started:
            return
        self.started = False
        try:
            self.rpc("luaeval('(function() pcall(require(\"opencode\").stop); return true end)()')")
        except Exception:
            pass
        subprocess.run([TMUX, "-L", SOCKET, "kill-server"], check=False)
        time.sleep(0.2)
        shutil.rmtree(self.root, ignore_errors=True)

    def rpc(self, expr, timeout=15):
        result = subprocess.run(
            [
                NVIM, "--clean", "--headless", "--server", self.server,
                "--remote-expr", expr,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        if result.returncode != 0:
            raise Failure(f"RPC failed for {expr}: {result.stderr.strip()}")
        return result.stdout

    def lua(self, code, timeout=15):
        return self.rpc("luaeval(" + json.dumps(code) + ")", timeout)

    def json_lua(self, code, timeout=15):
        return json.loads(self.lua("vim.json.encode(" + code + ")", timeout))

    def wait_rpc(self, code, timeout=20):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                value = self.lua(code)
                if value.strip() not in ("false", "nil", ""):
                    return value
            except Exception as error:
                last = error
            time.sleep(0.1)
        raise Failure(f"RPC condition timed out: {code} ({last})")

    def send(self, *keys):
        subprocess.run(
            [TMUX, "-L", SOCKET, "send-keys", "-t", SESSION, *keys],
            check=True,
        )

    def send_text(self, text):
        subprocess.run(
            [TMUX, "-L", SOCKET, "send-keys", "-t", SESSION, "-l", text],
            check=True,
        )

    def capture(self):
        return subprocess.run(
            [TMUX, "-L", SOCKET, "capture-pane", "-p", "-t", SESSION],
            stdout=subprocess.PIPE,
            text=True,
            check=True,
        ).stdout

    def pane_cursor(self):
        output = subprocess.run(
            [
                TMUX, "-L", SOCKET, "display-message", "-p", "-t", SESSION,
                "#{cursor_x},#{cursor_y}",
            ],
            stdout=subprocess.PIPE,
            text=True,
            check=True,
        ).stdout.strip()
        x, y = output.split(",", 1)
        return int(x), int(y)

    def wait_pane(self, text, timeout=10, absent=False):
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            last = self.capture()
            present = text in last
            if present != absent:
                return last
            time.sleep(0.1)
        raise Failure(f"pane never {'lost' if absent else 'gained'} {text!r}\n{last}")

    def mode(self):
        return self.json_lua("vim.api.nvim_get_mode().mode")

    def run(self):
        self.start()
        self.send("Space", "o", "o")
        self.wait_pane("Ask anything", timeout=20)
        self.wait_rpc("require('opencode').is_running()", timeout=20)
        time.sleep(0.5)
        check(self.mode().strip('"') == "t", "TUI should start in Terminal mode")

        # Remember a manually adjusted vertical width across close/open.
        target_width = min(70, int(self.lua("tostring(vim.o.columns)")) - 2)
        self.lua(
            "vim.api.nvim_win_set_width("
            "require('opencode').get_state().terminal.window, "
            + str(target_width)
            + ")"
        )
        self.lua("require('opencode').close()")
        time.sleep(0.3)
        self.lua("require('opencode').open()")
        self.wait_pane("Build · Big Pickle OpenCode", timeout=5)
        restored_width = int(self.json_lua(
            "vim.api.nvim_win_get_width(require('opencode').get_state().terminal.window)"
        ))
        check(restored_width == target_width,
              f"width memory restored {restored_width}, expected {target_width}")
        time.sleep(0.3)

        # Text, including literal "jk", goes to OpenCode even with a global
        # Terminal-mode "jk" mapping.
        self.send_text("jk alpha beta gamma")
        self.send("C-j")
        self.send_text("delta epsilon")
        self.wait_pane("jk alpha beta gamma")
        self.wait_pane("delta epsilon")
        check(self.mode().strip('"') == "t",
              "global Terminal jk mapping stole text from the TUI")
        before = self.pane_cursor()

        # Alt-b/Alt-f are handled by OpenCode; typing immediately after shows
        # where the TUI cursor really moved.
        self.send("M-b")
        time.sleep(0.3)
        after_b = self.pane_cursor()
        check(after_b != before, f"TUI cursor did not move for Alt-b: {before} -> {after_b}")
        self.send_text("X")
        time.sleep(0.2)
        self.wait_pane("delta Xepsilon")
        self.send("M-f")
        time.sleep(0.3)
        self.send_text("Y")
        time.sleep(0.2)
        self.wait_pane("delta XepsilonY")

        # Native leader combination: ctrl+x l is OpenCode's session list.
        self.send("C-x", "l")
        self.wait_pane("Sessions for project", timeout=5)
        self.send("Escape")
        time.sleep(0.3)

        # Hide and reveal the window; Terminal mode is restored.
        self.lua("require('opencode').close()")
        time.sleep(0.5)
        self.wait_pane("Build · Big Pickle OpenCode", absent=True)
        self.lua("require('opencode').open()")
        self.wait_pane("Build · Big Pickle OpenCode", timeout=5)
        time.sleep(0.3)
        check(self.mode().strip('"') == "t",
              "revealed TUI window is not in Terminal mode")
        self.send_text("Z")
        time.sleep(0.2)
        self.wait_pane("Z")

        # Explicitly leaving Terminal mode is corrected back to Terminal mode;
        # there is no Normal routing.
        self.send("C-\\", "C-n")
        time.sleep(0.5)
        check(self.mode().strip('"') == "t",
              "Ctrl-\\ Ctrl-n left the OpenCode window in Normal mode")
        self.send_text("Q")
        time.sleep(0.2)
        self.wait_pane("Q")

        print("tmux e2e: OK")


def main():
    if not (NVIM and TMUX and OPENCODE):
        print("tmux e2e: SKIP (nvim, tmux and opencode are required)", file=sys.stderr)
        return 0
    os.makedirs(BASE, exist_ok=True)
    e2e = E2E()
    try:
        e2e.run()
        return 0
    except Exception:
        traceback.print_exc()
        try:
            print("---- pane ----")
            print(e2e.capture())
            print("---- mode ----")
            print(e2e.mode())
        except Exception:
            pass
        return 1
    finally:
        e2e.stop()


if __name__ == "__main__":
    sys.exit(main())
