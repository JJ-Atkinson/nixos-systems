"""Emulate systemd socket activation for disposable GnuPG test daemons."""
import os
from pathlib import Path
import socket
import sys

if sys.argv[1] == "--keyboxd":
    agent, home, standard = sys.argv[2:]
    socket_paths = (standard,)
    descriptor_names = "std"
    options = []
else:
    agent, home, standard, extra = sys.argv[1:]
    ssh_socket = str(Path(standard).with_name("S.gpg-agent.ssh"))
    socket_paths = (standard, extra, ssh_socket)
    descriptor_names = "std:extra:ssh"
    options = ["--options", os.environ["YUBIGPG_TEST_AGENT_CONFIG"]] if os.environ.get("YUBIGPG_TEST_AGENT_CONFIG") else ["--no-options", "--disable-check-own-socket"]
listeners = []
for path in socket_paths:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen()
    listeners.append(listener)
for index, listener in enumerate(listeners):
    os.dup2(listener.fileno(), 3 + index)
    os.set_inheritable(3 + index, True)
os.environ.update(LISTEN_PID=str(os.getpid()), LISTEN_FDS=str(len(listeners)),
                  LISTEN_FDNAMES=descriptor_names)
os.execv(agent, [agent, "--supervised", *options, "--homedir", home])
