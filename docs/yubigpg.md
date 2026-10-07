# Receiver-side manual GPG socket selection

`yubigpg` runs on the machine doing GPG operations. It selects the socket used
by **ordinary GPG clients**, including Git, without wrapping GPG or SSH:

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
```

`use local` points the standard socket at `.local`; `use fwd` points it at `.fwd`.
Each new GPG connection follows that route. There are no separate GPG sessions,
alternate keyrings, executable aliases, client connection helpers, or required
changes to an application's GPG executable.

Selection is per user and persistent in `$XDG_STATE_HOME/yubigpg/mode`, defaulting
to `~/.local/state/yubigpg/mode`. The initial mode is `local`. A systemd user
oneshot restores the symlink at user-manager startup. Switching requires no
rebuild, environment update, or agent restart. Existing in-flight connections
finish using their previous endpoint.

`fwd` never automatically falls back. The module configures GPG/GPGSM clients
with `no-autostart` so a disconnected tunnel does not cause them to spawn an
agent over the selector. Local systemd socket activation still works. Do not
override that setting with `--autostart` or a custom client configuration.

## Standard SSH configuration: `nixos` provides the key to Framework

On **`nixos`**, put this in `~/.ssh/config` before broader `Host *` defaults:

```sshconfig
Host nixos-framework
    HostName nixos-framework
    User jarrett
    RemoteForward /run/user/1000/gnupg/S.gpg-agent.fwd /run/user/1000/gnupg/S.gpg-agent.extra
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

`RemoteForward` carries GPG operations back to the provider's restricted extra
socket. `ForwardAgent` provides the provider's GPG-backed SSH identities for
onward SSH from the remote session. `IdentityAgent` selects the provider's local
SSH agent even if its shell inherited a different `SSH_AUTH_SOCK`.

The receiving-side `use` command controls **GPG socket selection only**.
SSH agent selection for the remote session follows `SSH_AUTH_SOCK`. The shared
Home Manager configuration preserves that variable when SSH supplies it.
Already-running receiver desktop applications keep their own SSH environment,
but ordinary GPG applications use the selected standard socket directly.

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
forwarded socket available for 60 seconds after the last session closes.

To close it immediately:

```console
ssh -O exit nixos-framework
```

Disconnecting does not change the selected GPG mode. In `fwd`, key operations
fail until another connection supplies the endpoint or you choose `local`.

The receiver's module enables `StreamLocalBindUnlink yes` in sshd, allowing
ordinary OpenSSH to replace stale forwarding sockets. Use multiplexing for
concurrent sessions: independently established connections to the same user's
`.fwd` path can replace each other's listener. Only one provider endpoint is
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
`no-autostart`, and enables SSH server stale-socket handling. It does not manage
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

## Status and troubleshooting

```text
Mode:       fwd
Agent:      reachable
GPG socket: /run/user/1000/gnupg/S.gpg-agent
Selected:   /run/user/1000/gnupg/S.gpg-agent.fwd
Forward to: /run/user/1000/gnupg/S.gpg-agent.fwd
Route:      configured
Key/card:   not checked (reachability does not prove key availability)
```

`yubigpg status --json` produces machine-readable output. Probes do not launch
agents themselves, although connecting to a local systemd-owned socket can
activate its service. Agent reachability does not prove that a YubiKey is
attached or that a particular key is available.

- **Forwarded agent unavailable:** check that normal SSH connected successfully
  with the configured alias, and inspect `ssh -G nixos-framework` for
  `remoteforward`. Choose `local` explicitly if the key is now here.
- **Route not initialized:** inspect `systemctl --user status yubigpg-router`;
  `yubigpg init` restores the route once the module owns the local socket.
- **Extra socket absent on provider:** check `gpg-agent-extra.socket` there.
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
forwarding does not steal the route or fall back. They also test persistence,
path preservation, and ordinary OpenSSH parsing of both forwarding mechanisms.
The restricted-socket transport test uses a Unix relay; hardware PIN/touch and
the real two-machine SSH workflow need the acceptance check above.

```console
nix build --impure --no-link --expr 'let f = builtins.getFlake "path:/etc/nixos"; in f.nixosConfigurations.nixos-framework.config.programs.yubigpg.package'
```

Reference: [GnuPG agent forwarding](https://wiki.gnupg.org/AgentForwarding).
