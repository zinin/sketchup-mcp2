"""M-06 (spec §7.1–7.2): sketchup_mcp.auth — the token check, the nonces and
the HMAC proofs of the handshake.

The vector (conftest's ``auth_vectors``) is pinned here and in
test/test_auth.rb, so the Ruby and Python halves cannot drift apart.
"""
import re

import pytest

from sketchup_mcp import auth
from sketchup_mcp.errors import AuthenticationError, SketchUpError

HINT = ("Copy the token from SketchUp (Extensions → MCP Server → Settings...) into "
        "SKETCHUP_MCP_TOKEN in the MCP client's config, then restart the MCP client.")


def test_proofs_match_the_cross_language_vector(auth_vectors):
    v = auth_vectors
    assert auth.proof(v.token, "server", v.client_nonce, v.server_nonce) == v.server_proof
    assert auth.proof(v.token, "client", v.client_nonce, v.server_nonce) == v.client_proof


def test_proof_needs_a_known_role(auth_vectors):
    v = auth_vectors
    with pytest.raises(ValueError):
        auth.proof(v.token, "admin", v.client_nonce, v.server_nonce)


def test_new_nonce_is_64_hex():
    first, second = auth.new_nonce(), auth.new_nonce()
    assert re.fullmatch(r"[0-9a-f]{64}", first)
    assert first != second


def test_check_token_names_a_missing_token():
    with pytest.raises(AuthenticationError) as ei:
        auth.check_token(None)
    assert ei.value.code == -32003
    assert ei.value.message == f"SKETCHUP_MCP_TOKEN is not set. {HINT}"


def test_check_token_names_the_length_of_a_malformed_one():
    with pytest.raises(AuthenticationError) as ei:
        auth.check_token("abc")
    assert ei.value.message == (
        "SKETCHUP_MCP_TOKEN is not a token from the SketchUp plugin: "
        f"expected 64 hex characters, got 3. {HINT}")


def test_check_token_returns_a_well_formed_one(auth_vectors):
    assert auth.check_token(auth_vectors.token) == auth_vectors.token


def test_the_hint_names_the_extensions_menu():
    assert auth.COPY_TOKEN_HINT == HINT


def test_authentication_error_is_a_sketchup_error():
    err = AuthenticationError("m")
    assert isinstance(err, SketchUpError)
    assert (err.code, err.message, err.data) == (-32003, "m", {})
