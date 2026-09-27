# ==============================================================================
# claude-remote-ssh: Desktop Installation & Registration (Windows)
# Compatible with Windows PowerShell 5.1+ and PowerShell 7+
# ==============================================================================

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Desktop Client Setup: claude-remote-ssh (Windows)   " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# --- Prerequisite Check ---
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue

if (-not $nodeCmd -or -not $npxCmd) {
    Write-Host "[!] Warning: Node.js / npx was not detected in PATH." -ForegroundColor Yellow
    Write-Host "    Install Node.js 20+ from https://nodejs.org before running Claude MCP." -ForegroundColor Yellow
    Write-Host ""
}

# --- Interactive Prompts ---
$rawGistInput = Read-Host "Enter Gist Raw URL (e.g. https://gist.githubusercontent.com/.../raw/topo_tunnel.txt)"
$sshUser      = Read-Host "Enter SSH target user [default: user]"
if ([string]::IsNullOrWhiteSpace($sshUser)) { $sshUser = "user" }
$hostAlias    = Read-Host "Enter SSH Host alias [default: topo-server]"
if ([string]::IsNullOrWhiteSpace($hostAlias)) { $hostAlias = "topo-server" }

if ([string]::IsNullOrWhiteSpace($rawGistInput)) {
    Write-Host "[x] Error: Gist Raw URL is required." -ForegroundColor Red
    exit 1
}

# Clean out commit hash if user copied a specific commit raw URL
# e.g. .../raw/<40-char-hash>/file -> .../raw/file
$cleanedGistUrl = $rawGistInput -replace 'raw/[0-9a-fA-F]{40}/', 'raw/'

# --- Install sync script ---
$targetDir = Join-Path $env:USERPROFILE ".claude-remote-ssh"
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$targetScript = Join-Path $targetDir "update-tunnel.ps1"

$templatePath = Join-Path $PSScriptRoot "update-tunnel.ps1"
if (-not (Test-Path $templatePath)) {
    Write-Host "[x] Template script not found: $templatePath" -ForegroundColor Red
    exit 1
}

$scriptBody = Get-Content $templatePath -Raw
$scriptBody = $scriptBody -replace '\{\{GIST_RAW_URL\}\}', $cleanedGistUrl
$scriptBody = $scriptBody -replace '\{\{SSH_USER\}\}', $sshUser
$scriptBody = $scriptBody -replace '\{\{HOST_ALIAS\}\}', $hostAlias

[System.IO.File]::WriteAllText($targetScript, $scriptBody, [System.Text.UTF8Encoding]::new($false))
Write-Host "[+] Installed sync script to: $targetScript" -ForegroundColor Green

# --- Initial sync test ---
Write-Host "[i] Performing initial endpoint resolution..." -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -File $targetScript

# --- Register Scheduled Task ---
$taskName = "UpdateTunnel_${hostAlias}"
Write-Host "[+] Registering Windows Scheduled Task: $taskName..." -ForegroundColor Green

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NonInteractive -NoProfile -WindowStyle Hidden -File `"$targetScript`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Settings $settings `
    -Description "Automated background sync of SSH endpoint for $hostAlias" -Force | Out-Null

# --- Configure Claude Desktop MCP (PS 5.1 + 7 compatible) ---
Write-Host "[+] Registering MCP tool in Claude Desktop configuration..." -ForegroundColor Green

$candidatePaths = @(
    "$env:APPDATA\Claude\claude_desktop_config.json",
    "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json"
)

foreach ($configPath in $candidatePaths) {
    $parent = Split-Path $configPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Read existing config if present (graceful fallback on invalid JSON)
    $configObj = $null
    if (Test-Path $configPath) {
        try {
            $existingRaw = Get-Content $configPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($existingRaw)) {
                $configObj = $existingRaw | ConvertFrom-Json
            }
        } catch {
            Write-Host "[!] Warning: Existing config at $configPath was invalid JSON. Starting fresh." -ForegroundColor Yellow
            $configObj = $null
        }
    }

    if ($null -eq $configObj) {
        $configObj = [PSCustomObject]@{}
    }

    # Ensure mcpServers exists
    if (-not $configObj.PSObject.Properties['mcpServers']) {
        $configObj | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([PSCustomObject]@{})
    }

    # Build the mcp-ssh server entry
    $sshServerEntry = [PSCustomObject]@{
        command = "npx.cmd"
        args    = @("-y", "@aiondadotcom/mcp-ssh")
    }

    # Add or overwrite mcp-ssh entry
    if ($configObj.mcpServers.PSObject.Properties['mcp-ssh']) {
        $configObj.mcpServers.'mcp-ssh' = $sshServerEntry
    } else {
        $configObj.mcpServers | Add-Member -MemberType NoteProperty -Name 'mcp-ssh' -Value $sshServerEntry
    }

    # Serialize and write (UTF-8 without BOM)
    $updatedJson = $configObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($configPath, $updatedJson, [System.Text.UTF8Encoding]::new($false))
    Write-Host "    Configured: $configPath" -ForegroundColor Green
}

# --- Done ---
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Desktop Setup Complete!" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Next Steps:"
Write-Host "  1. Exit Claude Desktop completely from system tray (Quit)."
Write-Host "  2. Relaunch Claude Desktop."
Write-Host "  3. Test connection in chat: 'Run hostname on $hostAlias via SSH'"
Write-Host ""
