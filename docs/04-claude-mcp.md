# 04 - Claude MCP Configuration

## Architecture Overview

Claude Desktop interacts with the host operating system using the Model Context Protocol (MCP). The `@aiondadotcom/mcp-ssh` server connects over standard I/O and transparently references the local `~/.ssh/config` file.

```
Claude Desktop <---> stdio <---> npx @aiondadotcom/mcp-ssh <---> ssh topo-server
```

## Configuration Locations

Windows installs store configuration in one of two paths:
- **Standard**: `%APPDATA%\Claude\claude_desktop_config.json`
- **Windows Store/MSIX**: `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json`

## Manual JSON Structure
```json
{
  "mcpServers": {
    "mcp-ssh": {
      "command": "npx.cmd",
      "args": [
        "-y",
        "@aiondadotcom/mcp-ssh"
      ]
    }
  }
}
```

*Note for macOS/Linux: Change `npx.cmd` to `npx`.*