# ==============================================================================
# claude-remote-ssh: Desktop Installation & Registration (Windows)
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

# Verify prerequisites
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue

if (-not $nodeCmd -or -not $npxCmd) {
    Write-Host "[!] Warning: Node.js / npx was not detected in PATH." -ForegroundColor Yellow
    Write-Host "    Install Node.js 20+ from https://nodejs.org before running Claude MCP." -ForegroundColor Yellow
}

$rawGistInput = Read-Host "Enter Gist Raw URL (e.g. https://gist.githubusercontent.com/.../raw/topo_tunnel.txt)"
$sshUser      = Read-Host "Enter SSH target user [default: ubuntu]"
if ([string]::IsNullOrWhiteSpace($sshUser)) { $sshUser = "ubuntu" }
$hostAlias    = Read-Host "Enter SSH Host alias [default: topo-server]"
if ([string]::IsNullOrWhiteSpace($hostAlias)) { $hostAlias = "topo-server" }

if ([string]::IsNullOrWhiteSpace($rawGistInput)) {
    Write-Host "[x] Error: Gist Raw URL is required." -ForegroundColor Red
    exit 1
}

# Clean out commit hashes if user copied a specific commit raw URL
# Transform https://gist.githubusercontent.com/user/id/raw/<hash>/file -> .../raw/file
$cleanedGistUrl = $rawGistInput -replace 'raw/[0-9a-fA-F]{40}/', 'raw/'

# Target script install directory
$targetDir = Join-Path $env:USERPROFILE ".claude-remote-ssh"
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$targetScript = Join-Path $targetDir "update-tunnel.ps1"

# Read source template script and substitute parameters safely
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

# Perform an initial sync check
Write-Host "[i] Performing initial endpoint resolution..." -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -File $targetScript

# Configure Task Scheduler
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

# Setup Claude Desktop MCP Configuration Safely (Merging without overwrite)
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

    $configObj = [ordered]@{}
    if (Test-Path $configPath) {
        try {
            $existingRaw = Get-Content $configPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($existingRaw)) {
                $configObj = $existingRaw | ConvertFrom-Json -AsHashtable
            }
        } catch {
            Write-Host "[!] Warning: Existing config at $configPath was invalid JSON. Starting fresh." -ForegroundColor Yellow
            $configObj = [ordered]@{}
        }
    }

    if (-not $configObj.ContainsKey("mcpServers")) {
        $configObj["mcpServers"] = [ordered]@{}
    }

    $configObj["mcpServers"]["mcp-ssh"] = [ordered]@{
        "command" = "npx.cmd"
        "args"    = @("-y", "@aiondadotcom/mcp-ssh")
    }

    $updatedJson = $configObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($configPath, $updatedJson, [System.Text.UTF8Encoding]::new($false))
    Write-Host "    Configured: $configPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Desktop Setup Complete!" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Next Steps:"
Write-Host "  1. Exit Claude Desktop completely from system tray (Quit)."
Write-Host "  2. Relaunch Claude Desktop."
Write-Host "  3. Test connection in chat: 'Run hostname on $hostAlias via SSH'"
Write-Host ""