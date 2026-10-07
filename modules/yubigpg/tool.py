"""Receiver-side selection of the socket used by ordinary GnuPG clients."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote


class Error(Exception):
    pass


class Tool:
    def __init__(self, config=None):
        config = config or {}
        self.home = Path.home()
        self.gpg_home = self.home / ".gnupg"
        self.state = Path(os.environ.get("XDG_STATE_HOME") or self.home / ".local/state") / "yubigpg"
        self.gpgconf = config.get("gpgconf", shutil.which("gpgconf"))
        self.timeout = config.get("probeTimeout", 3)

    @staticmethod
    def private_dir(path):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.chmod(0o700)

    @contextlib.contextmanager
    def lock(self):
        self.private_dir(self.state)
        with (self.state / "lock").open("a") as stream:
            os.chmod(self.state / "lock", 0o600)
            fcntl.flock(stream, fcntl.LOCK_EX)
            yield

    @staticmethod
    def atomic_write(path, text):
        fd, name = tempfile.mkstemp(prefix=".yubigpg-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(text)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def mode(self):
        try:
            mode = (self.state / "mode").read_text().strip()
        except FileNotFoundError:
            return "local"
        if mode not in ("local", "fwd"):
            raise Error("Invalid mode file. Repair it with 'yubigpg use local' or 'yubigpg use fwd'.")
        return mode

    def paths(self):
        result = subprocess.run(
            [self.gpgconf, "--homedir", str(self.gpg_home), "--list-dirs", "agent-socket"],
            check=True, capture_output=True, text=True, timeout=self.timeout,
        )
        standard = Path(unquote(result.stdout.strip()))
        if not standard.is_absolute() or standard.name != "S.gpg-agent":
            raise Error("GnuPG returned an unexpected standard socket path.")
        return {"standard": standard, "local": standard.with_name("S.gpg-agent.local"),
                "fwd": standard.with_name("S.gpg-agent.fwd")}

    def probe(self, path):
        """Probe Assuan directly; never spawn an agent or perform key operations."""
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                deadline = time.monotonic() + self.timeout
                connection.settimeout(self.timeout)
                connection.connect(str(path))
                buffer = b""

                def read_line():
                    nonlocal buffer
                    while b"\n" not in buffer:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise TimeoutError
                        connection.settimeout(remaining)
                        data = connection.recv(4096)
                        if not data or len(buffer) + len(data) > 8192:
                            return b""
                        buffer += data
                    line, buffer = buffer.split(b"\n", 1)
                    return line

                if not read_line().startswith(b"OK"):
                    return "unavailable"
                connection.sendall(b"GETINFO version\n")
                version_received = False
                for _ in range(16):
                    line = read_line()
                    if line.startswith(b"D "):
                        version_received = True
                    elif line.startswith(b"OK"):
                        return "reachable" if version_received else "unavailable"
                    elif not line or line.startswith(b"ERR"):
                        return "unavailable"
                return "unavailable"
        except TimeoutError:
            return "timed out"
        except OSError:
            return "unavailable"

    def check_standard(self, path):
        """Never replace a live socket belonging to an old agent installation."""
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            if target not in ("S.gpg-agent.local", "S.gpg-agent.fwd"):
                raise Error(f"Refusing to replace an unrelated symlink at {path}.")
            return
        if not stat.S_ISSOCK(info.st_mode):
            raise Error(f"Refusing to replace a non-socket at {path}.")
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(self.timeout)
            try:
                connection.connect(str(path))
            except ConnectionRefusedError:
                return  # A dead socket may be atomically replaced by the selector.
            except FileNotFoundError:
                return
            except OSError as exc:
                raise Error(f"Cannot determine whether the old standard socket is active: {exc}") from exc
        raise Error("The standard socket still belongs to a running old agent. "
                    "Apply the socket-selector module and restart its GPG units before initializing it.")

    def route(self, mode, persist=True):
        paths = self.paths()
        standard = paths["standard"]
        self.check_standard(standard)
        self.private_dir(standard.parent)
        fd, temporary = tempfile.mkstemp(prefix=".yubigpg-socket-", dir=standard.parent)
        os.close(fd)
        os.unlink(temporary)
        try:
            os.symlink(paths[mode].name, temporary)
            os.replace(temporary, standard)
        finally:
            if os.path.lexists(temporary):
                os.unlink(temporary)
        if persist:
            self.atomic_write(self.state / "mode", mode + "\n")
        return paths

    def init(self):
        with self.lock():
            self.private_dir(self.gpg_home)
            result = subprocess.run(
                [self.gpgconf, "--homedir", str(self.gpg_home), "--create-socketdir"],
                capture_output=True, text=True,
            )
            paths = self.paths()
            # GnuPG uses the home itself in environments without /run/user;
            # --create-socketdir reports failure even though that fallback works.
            if result.returncode and paths["standard"].parent != self.gpg_home:
                raise Error(f"Cannot create socket directory: {result.stderr.strip()}")
            self.route(self.mode(), persist=False)

    def use(self, mode):
        with self.lock():
            paths = self.paths()
            if not paths["standard"].is_symlink():
                raise Error("Socket selector is not initialized. Apply the module or run 'yubigpg init'.")
            self.route(mode)
        print(f"Selected {mode}: {paths[mode]}" + (" (no fallback)" if mode == "fwd" else ""))

    def status(self, as_json=False):
        paths = self.paths()
        mode = self.mode()
        target = os.readlink(paths["standard"]) if paths["standard"].is_symlink() else None
        data = {"mode": mode, "agent": self.probe(paths[mode]), "gpgHome": str(self.gpg_home),
                "standardSocket": str(paths["standard"]), "selectedSocket": str(paths[mode]),
                "localSocket": str(paths["local"]), "forwardedSocket": str(paths["fwd"]),
                "routeMatchesMode": target == paths[mode].name, "keyAvailability": "not checked"}
        if as_json:
            print(json.dumps(data))
        else:
            print(f"Mode:       {mode}\nAgent:      {data['agent']}\n"
                  f"GPG socket: {data['standardSocket']}\nSelected:   {data['selectedSocket']}\n"
                  f"Forward to: {data['forwardedSocket']}\n"
                  f"Route:      {'configured' if data['routeMatchesMode'] else 'not initialized / mismatched'}\n"
                  "Key/card:   not checked (reachability does not prove key availability)")


def main():
    parser = argparse.ArgumentParser(prog="yubigpg", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    use = commands.add_parser("use", help="Select local or SSH-forwarded GPG for all ordinary clients")
    use.add_argument("mode", choices=["local", "fwd"])
    status = commands.add_parser("status", help="Show mode, socket routing, and agent reachability")
    status.add_argument("--json", action="store_true")
    commands.add_parser("init", help="Initialize/restore the socket route (normally run by systemd)")
    args = parser.parse_args()
    try:
        config_path = os.environ.get("YUBIGPG_CONFIG")
        config = json.loads(Path(config_path).read_text()) if config_path else {}
        tool = Tool(config)
        if args.command == "use":
            tool.use(args.mode)
        elif args.command == "status":
            tool.status(args.json)
        else:
            tool.init()
    except (Error, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"yubigpg: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
