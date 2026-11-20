# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub's private vulnerability reporting: open this repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them.

Say what is affected, how to reproduce it, and what an attacker gains. Fixes go into the next release; the report stays private until then.

## Scope

- The SketchUp plugin's TCP server: the token handshake, framing and the per-client limits, and the `eval_ruby` gate.
- The Python MCP server (`sketchup-mcp2`): the client side of the handshake, and what it sends and reports.

Some behaviour is by design and described in the README's [Security model](README.md#security-model): `eval_ruby` runs arbitrary Ruby for a client that has the token while the gate is open, and the traffic is not encrypted. A way to connect or run a tool without the token, to learn the token, or to run Ruby with the gate closed is in scope.

## Supported versions

Fixes go into the latest release only.
