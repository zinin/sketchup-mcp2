"""Socket authentication, client side (spec §7.1–7.2, M-06).

The SketchUp plugin makes a token — 32 random bytes as 64 lowercase hex
characters — and shows it in its Settings; the user copies it into
``SKETCHUP_MCP_TOKEN``. In the handshake each side proves it knows the token
without sending it: HMAC-SHA256 keyed with the token's 64 ASCII characters,
over ``"sketchup-mcp/1/<role>"`` followed by the client nonce and the server
nonce, all ASCII hex with no separator. ``core/auth.rb`` computes the same
proofs; both test suites pin one vector.
"""
import hashlib
import hmac
import re
import secrets

from sketchup_mcp.errors import AuthenticationError

# A token, a nonce or a proof: 64 lowercase hex characters.
TOKEN_RE = re.compile(r"[0-9a-f]{64}")

_ROLES = ("server", "client")

COPY_TOKEN_HINT = (
    "Copy the token from SketchUp (Extensions → MCP Server → Settings...) into "
    "SKETCHUP_MCP_TOKEN in the MCP client's config, then restart the MCP client."
)


def is_hex64(value: object) -> bool:
    return isinstance(value, str) and TOKEN_RE.fullmatch(value) is not None


def new_nonce() -> str:
    """32 random bytes as 64 lowercase hex characters."""
    return secrets.token_hex(32)


def proof(token: str, role: str, client_nonce: str, server_nonce: str) -> str:
    """The proof that ``role`` ("server" or "client") knows ``token``."""
    if role not in _ROLES:
        raise ValueError(f"role must be one of {', '.join(_ROLES)}, got {role!r}")
    message = f"sketchup-mcp/1/{role}{client_nonce}{server_nonce}".encode("ascii")
    return hmac.new(token.encode("ascii"), message, hashlib.sha256).hexdigest()


def check_token(token: str | None) -> str:
    """The token, when it has the form the plugin makes; otherwise
    AuthenticationError with the instruction. Called before any socket opens."""
    if token is None:
        raise AuthenticationError(f"SKETCHUP_MCP_TOKEN is not set. {COPY_TOKEN_HINT}")
    if not is_hex64(token):
        if len(token) == 64:
            problem = "it has 64 characters, but not all of them are lowercase hex (0-9, a-f)"
        else:
            problem = f"expected 64 lowercase hex characters (0-9, a-f), got {len(token)}"
        raise AuthenticationError(
            f"SKETCHUP_MCP_TOKEN is not a token from the SketchUp plugin: {problem}. {COPY_TOKEN_HINT}"
        )
    return token


def msg_unknown_token(host: str, port: int) -> str:
    """The server's proof did not match: the token here is wrong, or the server
    at that address is not the plugin (spec §7.2, step 3)."""
    return (
        f"The server at {host}:{port} does not know this token: SKETCHUP_MCP_TOKEN is wrong, "
        f"or the server is not the SketchUp MCP plugin. {COPY_TOKEN_HINT}"
    )


def msg_rejected(host: str, port: int) -> str:
    """The plugin refused this client's proof with -32003 (spec §7.2, step 5)."""
    return f"SketchUp at {host}:{port} rejected the token (authentication failed). {COPY_TOKEN_HINT}"
