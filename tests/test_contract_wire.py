"""M-09: every MCP tool reaches the real Ruby server with the arguments it sent.

tests/test_contract.py compares wire names as source text, and
test/test_dispatch_routing.rb drives Dispatch.call_handler directly; neither
puts the real client in front of the real server. Here each tool runs through
mcp.call_tool, a real SketchUpConnection carries it over a real socket (the
hello handshake included), and test/contract/echo_server.rb runs core/ and
dispatch.rb with an echo in place of every handler. Each tool must reach the
handler method named after its wire name, with the arguments Python sent.

It needs ruby on PATH, so it runs only when asked; CI runs it in the
`contract` job:

    SKETCHUP_MCP_CONTRACT=1 uv run --locked pytest tests/test_contract_wire.py -q
"""
import json
import os
import queue
import shutil
import subprocess
import threading
from pathlib import Path

import pytest
from mcp.server.fastmcp.exceptions import ToolError

from sketchup_mcp.app import mcp
from sketchup_mcp.connection import SketchUpConnection

pytestmark = pytest.mark.skipif(
    os.environ.get("SKETCHUP_MCP_CONTRACT") != "1" or not shutil.which("ruby"),
    reason="wire contract: needs SKETCHUP_MCP_CONTRACT=1 and ruby on PATH",
)

_ECHO_SERVER = (
    Path(__file__).resolve().parent.parent / "test" / "contract" / "echo_server.rb"
)
_WAIT = 10.0  # seconds: the longest any wait on the echo server may block

# The screenshot wrapper decodes png_base64 from the reply, which an echo does
# not carry, so its call raises after the round trip. Every other wrapper
# returns the reply as text.
_NO_TEXT_REPLY = "get_viewport_screenshot"

# dispatch.rb routes each wire name to the handler method of the same name,
# except this one: Handlers::View.viewport_screenshot.
_HANDLER_METHOD = {"get_viewport_screenshot": "viewport_screenshot"}


class _EchoServer:
    """test/contract/echo_server.rb in a subprocess, read line by line.

    A thread copies its stdout into a queue so that every read can time out.
    Its stderr, the plugin's log, is inherited: pytest shows it with a failure.
    """

    def __init__(self) -> None:
        self._proc = subprocess.Popen(
            ["ruby", str(_ECHO_SERVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        self._lines: queue.Queue = queue.Queue()
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        self.port = 0

    def _read_stdout(self) -> None:
        for line in self._proc.stdout:
            self._lines.put(line)
        self._lines.put(None)  # stdout closed: the process is exiting

    def _next(self, expected: str) -> str:
        try:
            line = self._lines.get(timeout=_WAIT)
        except queue.Empty:
            pytest.fail(f"echo server printed nothing in {_WAIT}s; expected {expected}")
        if line is None:
            pytest.fail(f"echo server exited; expected {expected}")
        return line

    def read_port(self) -> None:
        line = self._next("the `PORT <n>` line")
        key, _, value = line.strip().partition(" ")
        if key != "PORT" or not value.isdigit():
            pytest.fail(f"echo server printed {line!r}; expected the `PORT <n>` line")
        self.port = int(value)

    def next_line(self, expected: str) -> dict:
        line = self._next(expected)
        try:
            return json.loads(line)
        except ValueError:
            pytest.fail(f"echo server printed {line!r}; expected {expected}")

    def stop(self) -> None:
        self._proc.stdin.close()  # the harness exits when stdin closes
        try:
            self._proc.wait(timeout=_WAIT)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait()
        self._reader.join(timeout=_WAIT)
        self._proc.stdout.close()


@pytest.fixture
def echo_server():
    """A running echo server, stopped after the test even when the test fails."""
    server = _EchoServer()
    try:
        server.read_port()
        yield server
    finally:
        server.stop()


def _minimal_args(tool_name: str, schema: dict) -> dict:
    """The tool's required arguments only, so every other one is the wrapper's
    default: entity ids "1", "2", ..., material "red", any other string "x"."""
    args, ids = {}, 0
    for name in schema.get("required", []):
        if name == "id" or name.endswith("_id"):
            ids += 1
            args[name] = str(ids)
        elif name == "material":
            args[name] = "red"
        elif schema["properties"][name].get("type") == "string":
            args[name] = "x"
        else:
            pytest.fail(f"{tool_name}: no minimal value for required {name!r}; add one")
    return args


def _text_of(result) -> str:
    """The text a str-returning tool produced. call_tool returns its content
    blocks, paired with the structured output."""
    blocks = result[0] if isinstance(result, tuple) else result
    return blocks[0].text


async def test_every_mcp_tool_reaches_ruby_with_the_arguments_it_sent(
    echo_server, monkeypatch
):
    conn = SketchUpConnection("127.0.0.1", echo_server.port, timeout=5)
    sent = []
    send_command = conn.send_command

    async def recording_send_command(name, args):
        sent.append((name, args))
        return await send_command(name, args)

    async def get_connection():
        return conn

    conn.send_command = recording_send_command
    monkeypatch.setattr("sketchup_mcp.tools.get_connection", get_connection)
    try:
        listed = await mcp.list_tools()
        assert listed, "mcp.list_tools() lists no tools"
        for tool in listed:
            sent.clear()
            args = _minimal_args(tool.name, tool.inputSchema)
            if tool.name == _NO_TEXT_REPLY:
                with pytest.raises(ToolError, match="png_base64") as raised:
                    await mcp.call_tool(tool.name, args)
                reply = str(raised.value)
            else:
                reply = _text_of(await mcp.call_tool(tool.name, args))
                assert "[-32601]" not in reply, f"{tool.name}: {reply}"
            assert len(sent) == 1, f"{tool.name} sent {len(sent)} requests: {sent}"
            wire_name, sent_args = sent[0]
            logged = echo_server.next_line(
                f"the handler line for {tool.name} (wire name {wire_name!r}; "
                f"the tool answered {reply!r})"
            )
            method = logged["handler"].rpartition(".")[2]
            assert method == _HANDLER_METHOD.get(wire_name, wire_name), (
                f"{tool.name}: wire name {wire_name!r} reached {logged['handler']}"
            )
            assert logged["params"] == json.loads(json.dumps(sent_args)), (
                f"{tool.name}: Ruby got {logged['params']}, Python sent {sent_args}"
            )
        # The real hello handshake succeeded: the first call went through.
    finally:
        await conn.aclose()
