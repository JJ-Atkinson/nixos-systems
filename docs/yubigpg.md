# Receiver-side manual GPG and SSH-agent selection

`yubigpg` runs on the machine doing GPG/SSH operations. It selects the sockets
used by **ordinary GPG and OpenSSH clients**, including Git, without wrappers:

```console
yubigpg use local
yubigpg use fwd
yubigpg status
```

The provider is the machine with the USB YubiKey. It connects using normal
`ssh`, or any SSH-based tool that honors the same OpenSSH configuration.
Either `nixos` or `nixos-framework` can be provider or receiver.

## How it works

Both machines keep one normal GPG home and public keyring: `~/.gnupg`.
The NixOS module separates the real agent endpoints from GPG's standard socket:

```text
/run/user/1000/gnupg/S.gpg-agent.local   local systemd-managed GPG agent
/run/user/1000/gnupg/S.gpg-agent.fwd     socket supplied by ordinary SSH RemoteForward
/run/user/1000/gnupg/S.gpg-agent         symlink selected by yubigpg
/run/user/1000/gnupg/S.gpg-agent.ssh     local GPG-backed SSH agent (unchanged)
/run/user/1000/gnupg/S.gpg-agent.ssh.fwd fixed SSH-agent endpoint supplied by RemoteForward
/run/user/1000/gnupg/S.yubigpg-ssh-agent SSH-agent symlink selected by yubigpg
```

`use local` selects both local agents; `use fwd` selects both forwarded agents.
Each new agent connection follows the chosen route. There are no separate GPG sessions,
alternate keyrings, executable aliases, client connection helpers, or required
changes to an application's GPG executable.

Selection is per user and persistent in `$XDG_STATE_HOME/yubigpg/mode`, defaulting
to `~/.local/state/yubigpg/mode`. The initial mode is `local`. A systemd user
oneshot restores the symlink at user-manager startup. Switching requires no
rebuild, environment update, or agent restart. Existing in-flight connections
finish using their previous endpoint.

The local agent's `disable-check-own-socket` setting is required: GnuPG's
periodic watchdog checks the **canonical** socket even when systemd passes a
different listening pathname. Without this setting it exits about a minute
after selecting a different agent. Systemd manages the local agent's lifetime.

`fwd` never automatically falls back. The module configures GPG/GPGSM clients
with `no-autostart` so a disconnected tunnel does not cause them to spawn an
agent over the selector. Local systemd socket activation still works. Do not
override that setting with `--autostart` or a custom client configuration.

The module also replaces NixOS's GnuPG SSH tty-update `Match exec` hook with a
`gpg-connect-agent --no-autostart --raw-socket .../S.gpg-agent.local` command.
The original hook can spawn an unsupervised agent over the selector during an
outgoing SSH/Git operation when forwarding is unavailable. Client `gpg.conf`
does not apply to that helper. Agent reloads likewise address `.local`
explicitly. This replacement owns the system-wide `programs.ssh.extraConfig`
setting; your own `~/.ssh/config` entries remain the standard client interface.

## Standard SSH configuration: `nixos` provides the key to Framework

On **`nixos`**, put this in `~/.ssh/config` before broader `Host *` defaults:

```sshconfig
Host nixos-framework
    HostName nixos-framework
    User jarrett
    RemoteForward /run/user/1000/gnupg/S.gpg-agent.fwd /run/user/1000/gnupg/S.gpg-agent.extra
    RemoteForward /run/user/1000/gnupg/S.gpg-agent.ssh.fwd /run/user/1000/gnupg/S.gpg-agent.ssh
    ForwardAgent yes
    IdentityAgent /run/user/1000/gnupg/S.gpg-agent.ssh
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/yubigpg-%C
    ControlPersist 60
```

Use Framework's reachable DNS/Tailscale name or IP as `HostName` if needed.
These paths assume `jarrett` is UID 1000 and uses the normal GPG home on both
hosts. `yubigpg status` reports the receiver's exact forwarded endpoint;
`gpgconf --list-dirs agent-extra-socket` reports the provider's extra socket.

Then use your normal client:

```console
ssh nixos-framework
```

In that **same remote shell** on Framework:

```console
yubigpg use fwd
yubigpg status
git commit -S
ssh-add -L
```

The selection persists; there is no need to repeat `use fwd` on each connection.
Tools invoking `ssh nixos-framework ...`, `scp`, `sftp`, or a Git SSH remote
using this alias inherit the same forwarding configuration. Tools that disable
forwarding, ignore the config, or use an independent SSH implementation must
be configured through their own SSH settings.

The first `RemoteForward` carries GPG operations to the provider's restricted
extra socket. The second carries the SSH-agent protocol to its GPG SSH socket.
**Both entries are required for `use fwd` to select both kinds of operation.**
`IdentityAgent` in this provider host stanza deliberately uses the provider's
real local agent for authentication to the receiver. `ForwardAgent yes` also
provides ordinary session-scoped agent forwarding, but the selector uses the
second fixed `RemoteForward`, not SSH's randomly named per-session agent socket.

The module sets OpenSSH's default `IdentityAgent` to
`/run/user/%i/gnupg/S.yubigpg-ssh-agent` (`%i` is the local UID). Thus tools
wrapping ordinary SSH follow the selector even if they inherit another
`SSH_AUTH_SOCK`, such as a Herdr proxy wired to the local agent. Explicit
per-host `IdentityAgent` options still take precedence and bypass this default.

New login environments set `SSH_AUTH_SOCK` to the same stable selector for
direct agent consumers such as `ssh-add`. Existing applications retain their
old environment: ordinary OpenSSH uses the configured `IdentityAgent` anyway;
direct agent-protocol consumers must be relaunched or pointed at the selector:

```console
export SSH_AUTH_SOCK="/run/user/$(id -u)/gnupg/S.yubigpg-ssh-agent"
ssh-add -L
```

## Reverse direction

On **Framework**, use the same stanza with `Host nixos` and `HostName nixos`.
With its YubiKey attached, run:

```console
ssh nixos
```

On `nixos`, select `yubigpg use fwd`. The socket paths are identical when both
users have UID 1000 and the same standard home layout.

After physically moving the YubiKey to the receiving machine:

```console
yubigpg use local
```

## Shared SSH connections and lifetime

The multiplexing settings let multiple SSH-based tools reuse one transport and
one GPG forwarding listener. `ControlPersist 60` keeps the transport and its
forwarded sockets available for 60 seconds after the last session closes.

To close it immediately:

```console
ssh -O exit nixos-framework
```

Disconnecting does not change the selected GPG mode. In `fwd`, key operations
fail until another connection supplies the endpoint or you choose `local`.

The receiver's module enables `StreamLocalBindUnlink yes` in sshd, allowing
ordinary OpenSSH to replace stale forwarding sockets. Use multiplexing for
concurrent sessions: independently established connections to the same user's
fixed forwarding paths can replace each other's listener. Only one provider endpoint is
selected per receiving user; this is not a multi-provider agent multiplexer.

## Initial setup and module options

The module is enabled for both repository hosts in `flake.nix`:

```nix
{
  imports = [ ./modules/yubigpg.nix ];
  programs.yubigpg = {
    enable = true;
    probeTimeout = 3;
  };
}
```

It installs the receiver-side tool, configures systemd's local GPG socket and
route initialization, enables the GPG SSH and extra sockets, configures client
`no-autostart` and default SSH `IdentityAgent`, and enables SSH server stale-socket handling. It does not manage
your SSH client host entries, SSH authentication keys, or public GPG keys.
It does not require Home Manager. Existing desktop smartcard/pinentry support
and SSH-server/firewall configuration are provided by the repository's other
modules.

Apply the configuration on both machines before using the SSH stanza. On the
initial migration, GPG user units need to reload/restart because the local
listening socket changes; subsequent mode switches never restart them. The
selector refuses to overwrite an active socket belonging to the old layout.
If initial activation leaves the old agent listening at the standard path,
close current GPG operations and explicitly restart these **GPG-only** units:

```console
systemctl --user stop gpg-agent.service gpg-agent.socket gpg-agent-ssh.socket gpg-agent-extra.socket
systemctl --user restart yubigpg-router.service
systemctl --user start gpg-agent.socket gpg-agent-ssh.socket gpg-agent-extra.socket
```

Both normal keyrings need the YubiKey's public OpenPGP key. If the receiver
does not already have it, import it once, using ordinary GPG:

```console
# On the provider, before enabling forwarding for the alias, or with forwards disabled:
gpg --export YOUR_KEY_FINGERPRINT | ssh -o ClearAllForwardings=yes nixos-framework 'gpg --import'
```

No private keys are copied. The configured Git signing key must identify a
signing key available on the provider. PIN entry and physical touch occur on
the provider. Test with an actual signature; receiver-side `gpg --card-status`
is a local smartcard management command, not a forwarding test.

### Migration from the first wrapper-based implementation

Version 0.2 replaces `yubigpg connect`, `yubigpg gpg`, and `yubigpg-gpg` with the
receiver-side selector above. The module no longer sets Git's GPG executable
or a shell alias. Home Manager updates remove those settings; in an already
open shell that loaded the old alias, run `unalias gpg` or open a new shell.
The normal `~/.gnupg` keyring is used for both modes.

### Upgrade from GPG-only selection (0.2.x)

Version 0.3 also selects the GPG-backed SSH agent. Add the second `RemoteForward`
entry on the provider and recreate the pooled connection once so OpenSSH
establishes the new endpoint. Apply the module and run `yubigpg init` to create
the SSH selector link; this leaves the real local SSH listener at its existing
path and does not require another socket-layout migration. On the provider,
use `local`; on the receiver, use `fwd`. No mode-switch rebuilds are needed.

## Status and troubleshooting

```text
Mode:       fwd
GPG agent:  reachable
GPG socket: /run/user/1000/gnupg/S.gpg-agent
Selected:   /run/user/1000/gnupg/S.gpg-agent.fwd
Forward to: /run/user/1000/gnupg/S.gpg-agent.fwd
GPG route:  configured
SSH agent:  reachable (1 identities)
SSH socket: /run/user/1000/gnupg/S.yubigpg-ssh-agent
SSH fwd to: /run/user/1000/gnupg/S.gpg-agent.ssh.fwd
SSH route:  configured
Key/card:   not checked (reachability does not prove key availability)
```

`yubigpg status --json` produces machine-readable output, including separate GPG
and SSH availability. SSH probes request public identities, never a signature.
Probes do not launch
agents themselves, although connecting to a local systemd-owned socket can
activate its service. Agent reachability does not prove that a YubiKey is
attached or that a particular key is available.

- **Forwarded agent unavailable:** check that normal SSH connected successfully
  with the configured alias, and inspect `ssh -G nixos-framework` for
  `remoteforward`. Choose `local` explicitly if the key is now here.
- **Route not initialized:** inspect `systemctl --user status yubigpg-router`;
  `yubigpg init` restores the route once the module owns the local socket.
- **Route replaced / pinentry appears on the receiver in fwd mode:** check
  `pgrep -a -u "$UID" gpg-agent`. An unsupervised `--daemon` process may have
  replaced the canonical symlink. Version 0.2.1 disables the local watchdog and
  fixes the SSH tty-update hook that could autostart such a process. Apply it
  on both hosts, stop only the identified stray agent after closing any active
  GPG operation, restore the route, and restart the local GPG units. Do not
  kill the SSH transport or log out of the desktop to repair this.
- **Extra socket absent on provider:** check `gpg-agent-extra.socket` there.
- **GPG works but SSH is unavailable:** verify the second `RemoteForward` entry
  is active. Reusing a pooled connection created before that entry was added
  can leave the SSH endpoint absent. Check `ssh -G HOST` and restart that pool.
- **SSH prompts locally despite fwd selection:** inspect `ssh -G DESTINATION`
  for `identityagent` and check for a per-host override. For direct agent
  consumers, check `SSH_AUTH_SOCK`; a pre-existing proxy may still use the local
  agent. Set it to the selector path or relaunch the application.
- **No secret key:** ensure the receiver's normal public keyring has the key
  and that the provider has the matching YubiKey attached.
- **PIN prompt absent:** inspect pinentry and the provider's graphical session.
- **Wrong mode persists:** `yubigpg use local` resets it. A mode is user-wide,
  so all ordinary GPG clients share the choice.
- **Custom `GNUPGHOME`:** this module routes the standard `~/.gnupg` sockets;
  custom homes use their own sockets and are outside this selector.

## Tests

Implementation: `modules/yubigpg/tool.py`; package: `modules/yubigpg/package.nix`.
The package build runs tests with isolated homes and disposable software keys.
They emulate systemd's named socket descriptors with real supervised GPG
agents, switch the standard symlink, invoke **unmodified GPG and Git**, verify
forwarded signing/decryption and return to local signing, and check disconnected
forwarding does not steal the route or fall back. A 75-second regression crosses
the watchdog interval while the canonical forward is disconnected, then signs
locally again. The build also executes the actual generated SSH `Match exec`
hook against the local socket. Tests cover persistence, misrouting diagnostics,
path preservation, and ordinary OpenSSH parsing of both forwarding mechanisms.
An additional test uses real GPG SSH-agent sockets, an authentication subkey,
`ssh-add`, and `ssh-keygen -Y sign/verify` to test local, forwarded, disconnected,
and restored-local SSH operations through the same selector.
The restricted-socket transport test uses a Unix relay; hardware PIN/touch and
the real two-machine SSH workflow need the acceptance check above.

```console
nix build --impure --no-link --expr 'let f = builtins.getFlake "path:/etc/nixos"; in f.nixosConfigurations.nixos-framework.config.programs.yubigpg.package'
```

Reference: [GnuPG agent forwarding](https://wiki.gnupg.org/AgentForwarding).
