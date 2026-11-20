"""SketchUp MCP entry point.

The actual ``FastMCP`` instance and ``server_lifespan`` live in
``sketchup_mcp.app`` (which also triggers tool registration via
``sketchup_mcp.tools`` side-effect import).
"""
import argparse

from sketchup_mcp import __version__
from sketchup_mcp.app import mcp


def main() -> None:
    """CLI entry point: ``sketchup-mcp2`` and ``python -m sketchup_mcp``.

    ``--version`` prints the version and exits (M-21); with no arguments the
    MCP server runs on stdio.
    """
    parser = argparse.ArgumentParser(
        prog="sketchup-mcp2",
        description="MCP server for SketchUp: talks to the MCP plugin running inside SketchUp.",
    )
    parser.add_argument("--version", action="version", version=f"sketchup-mcp2 {__version__}")
    parser.parse_args()
    mcp.run()


if __name__ == "__main__":
    main()
