# ==============================================================================
# claude-remote-ssh: Non-Destructive SSH Config Synchronizer
# ==============================================================================

[CmdletBinding()]
param()

$gistBaseUrl = "{{GIST_RAW_URL}}"
$sshUser     = "{{SSH_USER}}"
$hostAlias   = "{{HOST_ALIAS}}"

# Cache buster to bypass raw.githubusercontent.com CDN edge caching
$cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$requestUri  = "${gistBaseUrl}?cb=${cacheBuster}"

try {
    $tunnelAddress = (Invoke-RestMethod -Uri $requestUri -Headers @{ "Cache-Control" = "no-cache"; "Pragma" = "no-cache" }).Trim()
} catch {
    Write-Warning "Failed to query Gist endpoint: $_"
    return
}

if ([string]::IsNullOrWhiteSpace($tunnelAddress) -or $tunnelAddress -eq "initial") {
    Write-Output "[i] Gist mailbox is currently uninitialized. Waiting for server..."
    return
}

# Parse tcp://hostname:port format
$sanitized = $tunnelAddress -replace '^tcp://', ''
$parts = $sanitized -split ':'
if ($parts.Count -lt 2) {
    Write-Warning "Malformed address received from Gist: $tunnelAddress"
    return
}

$newHost = $parts[0]
$newPort = $parts[1]

# Path to local SSH config
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

$configPath = Join-Path $sshDir "config"
if (-not (Test-Path $configPath)) {
    New-Item -ItemType File -Path $configPath -Force | Out-Null
}

$existingContent = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
if ($null -eq $existingContent) { $existingContent = "" }

# Define the exact Host block
$newBlock = @"
Host $hostAlias
    HostName $newHost
    User $sshUser
    Port $newPort
    AddressFamily inet
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    TCPKeepAlive yes
"@.Trim()

# Regex to detect existing Host alias block without touching other hosts
$blockRegex = "(?ms)(^|\r?\n)Host\s+$([regex]::Escape($hostAlias))\s*(\r?\n(?:[ \t]+[^\r\n]*\r?\n?)*)"

if ($existingContent -match $blockRegex) {
    $currentBlock = $Matches[0]
    if ($currentBlock -match "HostName\s+$([regex]::Escape($newHost))" -and $currentBlock -match "Port\s+$newPort") {
        Write-Output "[+] Tunnel configuration for '$hostAlias' is current (${newHost}:${newPort})."
        return
    }

    $updatedContent = [regex]::Replace($existingContent, $blockRegex, "`$1$newBlock")
} else {
    $updatedContent = ($existingContent.TrimEnd() + "`r`n`r`n" + $newBlock).Trim() + "`r`n"
}

[System.IO.File]::WriteAllText($configPath, $updatedContent, [System.Text.UTF8Encoding]::new($false))
Write-Output "[+] SSH configuration updated: $hostAlias -> ${newHost}:${newPort}"
