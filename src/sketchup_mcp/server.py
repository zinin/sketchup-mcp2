"""SketchUp MCP entry point.

The actual ``FastMCP`` instance and ``server_lifespan`` live in
``sketchup_mcp.app`` (which also triggers tool registration via
``sketchup_mcp.tools`` side-effect import).
"""
from sketchup_mcp.app import mcp


def main() -> None:
    """CLI entry point: ``sketchup-mcp`` and ``python -m sketchup_mcp``."""
    mcp.run()


if __name__ == "__main__":
    main()
