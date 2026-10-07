"""Emulate systemd's named socket descriptors for a disposable test agent."""
import os
from pathlib import Path
import socket
import sys

agent, home, standard, extra = sys.argv[1:]
listeners = []
for path in (standard, extra):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen()
    listeners.append(listener)
for index, listener in enumerate(listeners):
    os.dup2(listener.fileno(), 3 + index)
    os.set_inheritable(3 + index, True)
os.environ.update(LISTEN_PID=str(os.getpid()), LISTEN_FDS="2", LISTEN_FDNAMES="std:extra")
options = ["--options", os.environ["YUBIGPG_TEST_AGENT_CONFIG"]] if os.environ.get("YUBIGPG_TEST_AGENT_CONFIG") else ["--no-options", "--disable-check-own-socket"]
os.execv(agent, [agent, "--supervised", *options, "--homedir", home])
