"""Socket-selector tests: all GPG/Git invocations use the real executables."""

import contextlib
import io
import json
import os
from pathlib import Path
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tool import Error, Tool

SCRIPT = Path(__file__).resolve().parents[1] / "tool.py"
LAUNCHER = Path(__file__).with_name("agent_launcher.py")


class SelectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="yubigpg-test-")
        self.home = Path(self.directory.name)
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.home), "GNUPGHOME": str(self.home / ".gnupg"),
            "XDG_STATE_HOME": str(self.home / "state"), "YUBIGPG_CONFIG": "",
        })
        self.environment.start()
        self.tool = Tool()
        self.tool.init()
        self.agents = []
        self.agent_homes = [self.tool.gpg_home]

    def tearDown(self):
        for agent, log in self.agents:
            agent.terminate()
            try:
                agent.wait(timeout=3)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()
            log.close()
        for home in self.agent_homes:
            subprocess.run([self.tool.gpgconf, "--homedir", str(home), "--remove-socketdir"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.environment.stop()
        self.directory.cleanup()

    def use(self, mode):
        with contextlib.redirect_stdout(io.StringIO()):
            self.tool.use(mode)

    def test_selection_is_a_persistent_standard_socket_symlink(self):
        paths = self.tool.paths()
        self.assertEqual(self.tool.mode(), "local")
        self.assertEqual(os.readlink(paths["standard"]), paths["local"].name)
        self.use("fwd")
        self.assertEqual(os.readlink(paths["standard"]), paths["fwd"].name)
        self.assertEqual(Tool().mode(), "fwd")
        self.assertEqual((self.tool.state / "mode").stat().st_mode & 0o777, 0o600)
        self.tool.init()
        self.assertEqual(os.readlink(paths["standard"]), paths["fwd"].name)
        self.use("local")
        self.assertEqual(os.readlink(paths["standard"]), paths["local"].name)

    def test_status_reports_unavailable_without_creating_an_agent(self):
        self.use("fwd")
        result = subprocess.run([sys.executable, str(SCRIPT), "status", "--json"], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["mode"], "fwd")
        self.assertEqual(data["agent"], "unavailable")
        self.assertTrue(data["routeMatchesMode"])
        self.assertFalse(Path(data["forwardedSocket"]).exists())
        self.assertEqual(data["gpgHome"], str(self.tool.gpg_home))

    def test_init_preserves_unrelated_paths_and_active_old_sockets(self):
        path = self.tool.paths()["standard"]
        path.unlink()
        path.write_text("keep this")
        with self.assertRaises(Error):
            self.tool.init()
        self.assertEqual(path.read_text(), "keep this")
        path.unlink()
        path.symlink_to("unrelated")
        with self.assertRaises(Error):
            self.tool.init()
        path.unlink()
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path))
            listener.listen()
            with self.assertRaises(Error):
                self.tool.init()
            self.assertTrue(path.is_socket())
        self.tool.init()
        self.assertEqual(os.readlink(path), "S.gpg-agent.local")

    def test_corrupt_mode_can_be_repaired(self):
        (self.tool.state / "mode").write_text("invalid")
        with self.assertRaises(Error):
            self.tool.mode()
        self.use("local")
        self.assertEqual(self.tool.mode(), "local")

    def test_status_never_claims_gpg_is_ready_when_route_is_replaced(self):
        path = self.tool.paths()["standard"]
        path.unlink()
        path.write_text("some other owner")
        result = subprocess.run([sys.executable, str(SCRIPT), "status", "--json"], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertFalse(data["routeMatchesMode"])
        self.assertEqual(data["agent"], "misrouted")

    def test_probe_timeout_for_nonresponsive_forward(self):
        path = self.tool.paths()["fwd"]
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path))
            listener.listen()
            # The listener accepts the kernel connection but sends no greeting.
            self.tool.timeout = 0.1
            started = time.monotonic()
            self.assertEqual(self.tool.probe(path), "timed out")
            self.assertLess(time.monotonic() - started, 1)

    def test_old_tty_helper_can_spawn_despite_gpg_client_no_autostart(self):
        # Reproduce the actual takeover: gpg-connect-agent does NOT read
        # gpg.conf, so client no-autostart cannot protect an unsafe SSH hook.
        (self.tool.gpg_home / "gpg.conf").write_text("no-autostart\n")
        self.use("fwd")
        paths = self.tool.paths()
        try:
            result = subprocess.run(
                ["gpg-connect-agent", "--homedir", str(self.tool.gpg_home), "--quiet", "updatestartuptty", "/bye"],
                capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(paths["standard"].is_symlink())
            self.assertTrue(paths["standard"].is_socket())
        finally:
            # This raw path belongs only to this disposable test home.
            subprocess.run(
                ["gpg-connect-agent", "--no-autostart", "--raw-socket", str(paths["standard"]), "KILLAGENT", "/bye"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
            )

    def test_plain_ssh_config_parses_gpg_and_ssh_forwarding(self):
        config = self.home / "ssh_config"
        receiver = self.tool.paths()["fwd"]
        source = "/run/user/1000/gnupg/S.gpg-agent.extra"
        config.write_text(f"""Host framework
    HostName 127.0.0.1
    User jarrett
    RemoteForward {receiver} {source}
    ForwardAgent yes
    IdentityAgent /run/user/1000/gnupg/S.gpg-agent.ssh
    ExitOnForwardFailure yes
    ControlMaster auto
    ControlPath ~/.ssh/yubigpg-%C
    ControlPersist 60
""")
        result = subprocess.run(["ssh", "-G", "-F", str(config), "framework"],
                                check=True, capture_output=True, text=True)
        self.assertIn(f"remoteforward {receiver} {source}\n", result.stdout)
        self.assertIn("forwardagent yes\n", result.stdout)
        self.assertIn("exitonforwardfailure yes\n", result.stdout)
        self.assertIn("controlmaster auto\n", result.stdout)

    def test_generated_agent_configuration_is_accepted(self):
        if os.environ.get("YUBIGPG_TEST_AGENT_CONFIG"):
            result = subprocess.run(
                ["gpg-agent", "--options", os.environ["YUBIGPG_TEST_AGENT_CONFIG"],
                 "--homedir", str(self.tool.gpg_home), "--gpgconf-test"], capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def start_agent(self, home, standard, extra):
        home.mkdir(mode=0o700, parents=True, exist_ok=True)
        log = (home / "test-agent.log").open("wb")
        agent = subprocess.Popen(
            [sys.executable, str(LAUNCHER), shutil.which("gpg-agent"), str(home), str(standard), str(extra)],
            stdout=log, stderr=subprocess.STDOUT,
        )
        self.agents.append((agent, log))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if agent.poll() is not None:
                self.fail((home / "test-agent.log").read_text())
            if self.tool.probe(standard) == "reachable":
                return
            time.sleep(0.02)
        self.fail("Supervised test agent did not start")

    def generate_key(self, home, name):
        subprocess.run(
            ["gpg", "--homedir", str(home), "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
             "--quick-generate-key", f"{name} <{name}@example.invalid>", "ed25519", "sign", "0"],
            check=True, capture_output=True,
        )
        listing = subprocess.run(["gpg", "--homedir", str(home), "--with-colons", "--list-keys"],
                                 check=True, capture_output=True, text=True).stdout
        fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        subprocess.run(
            ["gpg", "--homedir", str(home), "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
             "--quick-add-key", fingerprint, "cv25519", "encr", "0"], check=True, capture_output=True,
        )
        return fingerprint

    def test_ordinary_gpg_and_git_follow_socket_selection(self):
        paths = self.tool.paths()
        # This is the client config supplied by the module, not a GPG wrapper.
        (self.tool.gpg_home / "gpg.conf").write_text("no-autostart\n")
        self.start_agent(self.tool.gpg_home, paths["local"], paths["local"].with_name("S.gpg-agent.extra"))
        local_key = self.generate_key(self.tool.gpg_home, "local")

        provider = self.home / "provider"
        provider.mkdir(mode=0o700)
        self.agent_homes.append(provider)
        provider_socket = Path(subprocess.run(
            [self.tool.gpgconf, "--homedir", str(provider), "--list-dirs", "agent-socket"],
            check=True, capture_output=True, text=True,
        ).stdout.strip())
        extra = provider_socket.with_name("S.gpg-agent.extra")
        self.start_agent(provider, provider_socket, extra)
        remote_key = self.generate_key(provider, "remote")
        public = subprocess.run(["gpg", "--homedir", str(provider), "--export"],
                                check=True, capture_output=True).stdout
        subprocess.run(["gpg", "--import"], input=public, check=True, capture_output=True)

        class Proxy(socketserver.BaseRequestHandler):
            def handle(handler):
                with socket.socket(socket.AF_UNIX) as upstream:
                    upstream.connect(str(extra))
                    peers = [handler.request, upstream]
                    while True:
                        readable, _, _ = select.select(peers, [], [], 5)
                        if not readable:
                            return
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            (upstream if source is handler.request else handler.request).sendall(data)

        class Server(socketserver.ThreadingUnixStreamServer):
            daemon_threads = True

        message = b"An ordinary GPG client follows the socket selector\n"

        def sign(key):
            # No alternate GNUPGHOME, --homedir, custom executable, or helper.
            result = subprocess.run(["gpg", "--batch", "--local-user", key, "--armor", "--clearsign"],
                                    input=message, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            verified = subprocess.run(["gpg", "--verify"], input=result.stdout, capture_output=True)
            self.assertEqual(verified.returncode, 0, verified.stderr)

        sign(local_key)
        with Server(str(paths["fwd"]), Proxy) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                self.use("fwd")
                sign(remote_key)
                encrypted = subprocess.run(
                    ["gpg", "--batch", "--trust-model", "always", "--recipient", remote_key, "--encrypt"],
                    input=message, check=True, capture_output=True,
                )
                decrypted = subprocess.run(["gpg", "--batch", "--decrypt"], input=encrypted.stdout, capture_output=True)
                self.assertEqual(decrypted.returncode, 0, decrypted.stderr)
                self.assertEqual(decrypted.stdout, message)
                repo = self.home / "repo"
                environment = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
                subprocess.run(["git", "init", str(repo)], check=True, capture_output=True, env=environment)
                git = ["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                       "-c", f"user.signingkey={remote_key}"]
                committed = subprocess.run(git + ["commit", "-S", "--allow-empty", "-m", "Standard GPG signing"],
                                           capture_output=True, env=environment)
                self.assertEqual(committed.returncode, 0, committed.stderr)
                verified = subprocess.run(git + ["verify-commit", "HEAD"], capture_output=True, env=environment)
                self.assertEqual(verified.returncode, 0, verified.stderr)
                # The local socket is separate, and the canonical-path watchdog
                # is disabled exactly as it is in the NixOS module.
                self.assertIsNone(self.agents[0][0].poll())
            finally:
                server.shutdown()
                thread.join()
        disconnected = subprocess.run(["gpg", "--batch", "--local-user", remote_key, "--clearsign"],
                                      input=message, capture_output=True)
        self.assertNotEqual(disconnected.returncode, 0)
        self.assertEqual(os.readlink(paths["standard"]), "S.gpg-agent.fwd")
        self.assertEqual(self.tool.mode(), "fwd")
        # Exercise the actual SSH tty-update operation with a disconnected
        # canonical endpoint. It must use .local without autostarting a daemon.
        updated = subprocess.run(
            ["gpg-connect-agent", "--quiet", "--no-autostart", "--raw-socket", str(paths["local"]),
             "updatestartuptty", "/bye"], capture_output=True,
        )
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertEqual(os.readlink(paths["standard"]), "S.gpg-agent.fwd")
        if os.environ.get("YUBIGPG_TEST_SSH_CONFIG"):
            # Parse and execute the exact system-wide Match exec hook generated
            # by the package/module, rather than merely testing a hand-picked CLI.
            runtime = self.home / "runtime"
            runtime.mkdir()
            (runtime / "gnupg").symlink_to(self.tool.gpg_home)
            probe_config = self.home / "hook-ssh-config"
            probe_config.write_text(Path(os.environ["YUBIGPG_TEST_SSH_CONFIG"]).read_text().replace(
                "Match all", "    ServerAliveInterval 17\nMatch all", 1,
            ))
            parsed = subprocess.run(
                ["ssh", "-G", "-F", str(probe_config), "example.invalid"],
                env={**os.environ, "XDG_RUNTIME_DIR": str(runtime)}, capture_output=True,
            )
            self.assertEqual(parsed.returncode, 0, parsed.stderr)
            self.assertIn(b"serveraliveinterval 17\n", parsed.stdout)
            self.assertEqual(os.readlink(paths["standard"]), "S.gpg-agent.fwd")
        # Previously the supervised agent died ~64 seconds after a switch.
        # Test past a full watchdog interval, not just immediately after routing.
        time.sleep(75)
        self.assertIsNone(self.agents[0][0].poll(), (self.tool.gpg_home / "test-agent.log").read_text())
        self.assertEqual(self.tool.probe(paths["local"]), "reachable")
        self.assertEqual(os.readlink(paths["standard"]), "S.gpg-agent.fwd")
        self.use("local")
        sign(local_key)


if __name__ == "__main__":
    unittest.main()
