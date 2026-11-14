"""Ask a running KeyVault app for one API key. Standard library only.

    from keyvault_client import get_key
    api_key = get_key("OpenAI – production", reason="my-agent session")

How it works: KeyVault shows you a window naming this program and the key it wants. Only if
you approve does the key come back, over a private Unix socket (never the network). Your
master password is typed into KeyVault itself and never reaches this program.

Using the key safely:
  * Use it right away and don't copy it into child-process environments, logs, files or prompts.
    Anything a model-driven shell tool can read, a prompt-injected model can leak.
  * Python can't reliably erase a string from memory. The key stays in this process until it exits.
  * Turn on "Let programs request keys" in KeyVault (Settings → Agent Access) first. It's off by default.
"""
import json
import os
import pwd
import socket
import stat

__all__ = [
    "get_key", "default_socket_path", "KeyVaultError", "KeyVaultUnavailable", "KeyVaultDenied",
    "KeyVaultLocked", "KeyVaultRateLimited", "KeyVaultTimeout", "KeyVaultProtocolError",
]

_MAX_RESPONSE = 64 * 1024


class KeyVaultError(Exception):
    """Base class for everything this module raises."""


class KeyVaultUnavailable(KeyVaultError):
    """KeyVault isn't running, agent access is switched off, or the socket looks unsafe."""


class KeyVaultDenied(KeyVaultError):
    """You said no, the key doesn't exist, or the name matches more than one entry."""


class KeyVaultLocked(KeyVaultError):
    """The vault is locked and wasn't unlocked in time."""


class KeyVaultRateLimited(KeyVaultError):
    """Too many requests or refusals: this program is temporarily blocked."""


class KeyVaultTimeout(KeyVaultError):
    """Nobody answered the approval window in time."""


class KeyVaultProtocolError(KeyVaultError):
    """The reply wasn't what KeyVault sends."""


def default_socket_path():
    # The home directory comes from the user database, not $HOME, which a parent process can change.
    home = pwd.getpwuid(os.getuid()).pw_dir
    return os.path.join(home, "Library", "Application Support", "KeyVault", "agent.sock")


def _require_private(path, *, want_dir):
    try:
        info = os.lstat(path)  # lstat: a symlink is refused, not followed
    except FileNotFoundError:
        raise KeyVaultUnavailable(
            "KeyVault isn't listening. Open KeyVault and turn on Settings → Agent Access → "
            "'Let programs request keys'.") from None
    except OSError as e:
        raise KeyVaultUnavailable(f"Can't inspect {path}: {e.strerror}") from None
    kind_ok = stat.S_ISDIR(info.st_mode) if want_dir else stat.S_ISSOCK(info.st_mode)
    if not kind_ok:
        raise KeyVaultUnavailable(f"{path} is not what KeyVault creates; refusing to use it.")
    if info.st_uid != os.getuid():
        raise KeyVaultUnavailable(f"{path} belongs to another user; refusing to use it.")
    if info.st_mode & 0o077:
        raise KeyVaultUnavailable(f"{path} is accessible to other users; refusing to use it.")


def get_key(name, reason=None, timeout=150.0, socket_path=None):
    """Return the API key stored in KeyVault under `name`, after the user approves.

    `reason` is shown to the user as "the program says…", so keep it short and honest.
    `timeout` is the longest to wait for the user (approval and unlock windows included).
    """
    if not isinstance(name, str) or not name.strip():
        raise ValueError("name must be a non-empty string")
    path = socket_path or default_socket_path()
    _require_private(os.path.dirname(path), want_dir=True)
    _require_private(path, want_dir=False)

    request = {"v": 1, "op": "get", "key": name}
    if reason:
        request["reason"] = str(reason)[:200]
    payload = json.dumps(request).encode("utf-8") + b"\n"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(5.0)
        try:
            sock.connect(path)
        except (ConnectionRefusedError, FileNotFoundError):
            raise KeyVaultUnavailable("KeyVault isn't running or agent access is off.") from None
        sock.settimeout(timeout)
        sock.sendall(payload)
        buffer = b""
        while b"\n" not in buffer:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                raise KeyVaultTimeout("No answer from KeyVault in time.") from None
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > _MAX_RESPONSE:
                raise KeyVaultProtocolError("Reply too large.")
    finally:
        sock.close()

    try:
        reply = json.loads(buffer.split(b"\n", 1)[0].decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise KeyVaultProtocolError("Unreadable reply from KeyVault.") from None
    if not isinstance(reply, dict):
        raise KeyVaultProtocolError("Unexpected reply from KeyVault.")

    if reply.get("ok") is True:
        secret = reply.get("secret")
        if not isinstance(secret, str):
            raise KeyVaultProtocolError("Reply had no key.")
        return secret

    errors = {
        "denied": (KeyVaultDenied, "Access was denied (or no single key has that name)."),
        "locked": (KeyVaultLocked, "KeyVault is locked."),
        "rate_limited": (KeyVaultRateLimited, "Too many requests; try again in a few minutes."),
        "timeout": (KeyVaultTimeout, "The approval window timed out."),
        "bad_request": (KeyVaultProtocolError, "KeyVault rejected the request."),
    }
    cls, message = errors.get(reply.get("error"), (KeyVaultProtocolError, "Unknown error from KeyVault."))
    raise cls(message)
