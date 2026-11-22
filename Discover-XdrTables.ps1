<#
.SYNOPSIS
    Reports which Defender XDR advanced hunting tables hold data in this tenant, and records the
    result in the tenant's deploy config file.

.DESCRIPTION
    Reads the config file written by Prepare-Tenant.ps1 ($MsTenantId, $MsClientId,
    $MsClientSecret), gets an app token (client credentials, Graph scope) and runs one
    POST /v1.0/security/runHuntingQuery per table. Per table the result is:

      rows N     the table has N rows (7 days for tables with a Timestamp column, all time for
                 snapshot tables such as IdentityInfo)
      empty      the table exists and has 0 rows
      absent     the tenant has no such table ("Failed to resolve table ...")

    The table list is the advanced hunting tables the agent's XDR adapter reads, taken from
    internal/siem/xdr_adapter_kql.go (xdrRouting and the xdrBuildKQL* builders) and
    xdr_shared_defender.go (xdrBuildKQLCertInfo). Tables the adapter reads through Log Analytics
    (SigninLogs, AuditLogs, AAD*SignInLogs, MicrosoftGraphActivityLogs) are not listed.

    Right after admin consent the first calls return 403 for about a minute. A 403 is retried every
    20 seconds for up to 3 minutes. If it never clears, or any other call fails, the script warns,
    exits non-zero and leaves the config file untouched.

    On success it prints a table and writes one line per table into the config file between the
    markers "# BEGIN XdrTables" and "# END XdrTables" ($XdrTableRows). A re-run replaces that block.
    Nothing else in the file changes. The agent does NOT read $XdrTableRows: it probes every query
    type itself when it starts. The block is a record for the partner.

    After onboarding a new data source or a Defender add-on, re-run this script and restart the agent
    (the agent checks which telemetry exists only at startup).

.PARAMETER ConfigFile
    The config file written by Prepare-Tenant.ps1. Default: .\easysoc-deploy.config.ps1

.EXAMPLE
    .\Discover-XdrTables.ps1 -ConfigFile .\easysoc-deploy.config.ps1
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = ".\easysoc-deploy.config.ps1",

    # 403 retry: every RetryIntervalSeconds, for at most RetryMaxSeconds in total per call.
    [int]$RetryIntervalSeconds = 20,
    [int]$RetryMaxSeconds = 180
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$GraphScope      = "https://graph.microsoft.com/.default"
$HuntingUrl      = "https://graph.microsoft.com/v1.0/security/runHuntingQuery"
$BeginMarker     = "# BEGIN XdrTables"
$EndMarker       = "# END XdrTables"
$RerunNote       = "After onboarding a new data source or Defender add-on, re-run Discover-XdrTables.ps1 and restart the agent."

# Advanced hunting tables the XDR adapter reads. Timestamp = $false: snapshot table, no Timestamp
# column, so "T | count" instead of "T | where Timestamp > ago(7d) | count" (EXP-138).
function Get-XdrDiscoveryTable {
    $withTimestamp = @(
        "DeviceInfo", "DeviceProcessEvents", "DeviceNetworkEvents", "DeviceFileEvents",
        "DeviceRegistryEvents", "DeviceImageLoadEvents", "DeviceLogonEvents", "DeviceEvents",
        "DeviceFileCertificateInfo", "IdentityLogonEvents", "EmailEvents", "AlertEvidence", "AlertInfo"
    )
    $snapshot = @("IdentityInfo")
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $withTimestamp) { $list.Add([pscustomobject]@{ Name = $n; HasTimestamp = $true }) }
    foreach ($n in $snapshot)      { $list.Add([pscustomobject]@{ Name = $n; HasTimestamp = $false }) }
    return $list.ToArray()
}

# Dot-source the config in this function's scope and return the three values. Prints nothing.
function Read-DiscoveryConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    . $Path
    $out = @{}
    foreach ($n in @("MsTenantId", "MsClientId", "MsClientSecret")) {
        $v = Get-Variable -Name $n -ValueOnly -ErrorAction SilentlyContinue
        if (-not $v) { throw "$n is not set in $Path." }
        $out[$n] = [string]$v
    }
    if ($out["MsClientId"] -like "<DRY-RUN*" -or $out["MsClientSecret"] -like "<DRY-RUN*") {
        throw "$Path is a dry-run preview (placeholder app id / secret). Run Prepare-Tenant.ps1 without -DryRun first."
    }
    return $out
}

# Status code and body of a failed Invoke-RestMethod, on pwsh 7 and Windows PowerShell 5.1.
function Get-HttpErrorInfo {
    param($ErrorRecord)
    $status = 0
    $body = ""
    $resp = $null
    $ex = $ErrorRecord.Exception
    if ($ex.PSObject.Properties["Response"]) { $resp = $ex.Response }
    if ($resp -and $resp.PSObject.Properties["StatusCode"]) { $status = [int]$resp.StatusCode }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = [string]$ErrorRecord.ErrorDetails.Message
    } elseif ($resp -and $resp.PSObject.Properties["GetResponseStream"]) {
        try {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Dispose()
        } catch { $body = "" }
    }
    if ($status -eq 0 -and $ex.Message -match "\b(4\d\d|5\d\d)\b") { $status = [int]$Matches[1] }
    return [pscustomobject]@{ Status = $status; Body = $body }
}

# Client-credentials token. The secret goes only into the request body; it is never printed.
function Get-DiscoveryToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $form = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $GraphScope
    }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -ContentType "application/x-www-form-urlencoded" -Body $form
    } catch {
        $info = Get-HttpErrorInfo $_
        $desc = ""
        if ($info.Body -match '"error_description"\s*:\s*"([^"]*)"') { $desc = $Matches[1] }
        throw "Token request failed (HTTP $($info.Status)). $desc"
    }
    if (-not $resp.PSObject.Properties["access_token"] -or -not $resp.access_token) {
        throw "Token request returned no access_token."
    }
    return [string]$resp.access_token
}

# One table. Returns Name, State ('rows' | 'empty' | 'absent'), Rows (int, 0 unless State is 'rows').
# 403 is retried (admin consent has not propagated yet); throws when it does not clear or on any
# other failure.
function Get-XdrTableState {
    param([string]$Token, $Table)
    $kql = if ($Table.HasTimestamp) { "$($Table.Name) | where Timestamp > ago(7d) | count" } else { "$($Table.Name) | count" }
    $payload = @{ Query = $kql } | ConvertTo-Json -Compress
    $headers = @{ Authorization = "Bearer $Token" }
    $waited = 0
    while ($true) {
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $HuntingUrl -Headers $headers `
                -ContentType "application/json" -Body $payload
            break
        } catch {
            $info = Get-HttpErrorInfo $_
            if ($info.Status -eq 403) {
                if ($waited -ge $RetryMaxSeconds) {
                    throw "HTTP 403 for $($Table.Name) after $waited s: admin consent for ThreatHunting.Read.All has not taken effect."
                }
                Write-Host "      403 for $($Table.Name): waiting for admin consent to take effect (retry in $RetryIntervalSeconds s)" -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryIntervalSeconds
                $waited += $RetryIntervalSeconds
                continue
            }
            if ($info.Status -eq 400 -and $info.Body -match "(?i)failed to resolve table") {
                return [pscustomobject]@{ Name = $Table.Name; State = "absent"; Rows = 0 }
            }
            $snippet = if ($info.Body.Length -gt 200) { $info.Body.Substring(0, 200) } else { $info.Body }
            throw "HTTP $($info.Status) for $($Table.Name): $snippet"
        }
    }
    $results = @(if ($resp.PSObject.Properties["results"]) { $resp.results | ForEach-Object { $_ } })
    $rows = 0
    if ($results.Count -gt 0 -and $results[0].PSObject.Properties["Count"]) { $rows = [int64]$results[0].Count }
    $state = if ($rows -gt 0) { "rows" } else { "empty" }
    return [pscustomobject]@{ Name = $Table.Name; State = $state; Rows = $rows }
}

# The text between the markers: one line per table.
function New-XdrTablesBlock {
    param($Results, [string]$Generated)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($BeginMarker)
    $lines.Add("# Advanced hunting table check, written by Discover-XdrTables.ps1 on $Generated.")
    $lines.Add("# Value: row count (7 days; all time for IdentityInfo), 0 = empty, 'absent' = no such table.")
    $lines.Add("# The agent does NOT read this value: it probes every query type itself when it starts.")
    $lines.Add("# It is a record for the partner. $RerunNote")
    $lines.Add("`$XdrTableRows = @{")
    foreach ($r in $Results) {
        $v = if ($r.State -eq "absent") { "'absent'" } else { [string]$r.Rows }
        $lines.Add("    $($r.Name) = $v")
    }
    $lines.Add("}")
    $lines.Add($EndMarker)
    return ($lines -join "`n")
}

# Insert the block at the end of the file, or replace the existing one between the markers. The rest
# of the file stays byte-identical: bytes are read and written as they are (BOM kept), and the block
# takes the file's own newline style.
function Set-XdrTablesBlock {
    param([string]$Path, [string]$Block)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $text = $enc.GetString($bytes, $offset, $bytes.Length - $offset)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $blockText = $Block.Replace("`r`n", "`n").Replace("`n", $nl)

    $begin = $text.IndexOf($BeginMarker, [System.StringComparison]::Ordinal)
    if ($begin -ge 0) {
        $end = $text.IndexOf($EndMarker, $begin, [System.StringComparison]::Ordinal)
        if ($end -lt 0) { throw "$Path has '$BeginMarker' but no '$EndMarker'. Fix or remove the block by hand." }
        $newText = $text.Substring(0, $begin) + $blockText + $text.Substring($end + $EndMarker.Length)
    } else {
        $newText = $text
        if ($newText.Length -gt 0 -and -not $newText.EndsWith("`n")) { $newText += $nl }
        $newText += $nl + $blockText + $nl
    }
    $body = $enc.GetBytes($newText)
    $out = [byte[]]::new($offset + $body.Length)
    if ($offset -gt 0) { [Array]::Copy($bytes, 0, $out, 0, $offset) }
    [Array]::Copy($body, 0, $out, $offset, $body.Length)
    [System.IO.File]::WriteAllBytes($Path, $out)
}

function Invoke-XdrTableDiscovery {
    param([string]$Path)
    $cfg = Read-DiscoveryConfig -Path $Path
    Write-Host ""
    Write-Host "XDR advanced hunting table discovery (tenant $($cfg['MsTenantId']))" -ForegroundColor Cyan
    $token = Get-DiscoveryToken -TenantId $cfg["MsTenantId"] -ClientId $cfg["MsClientId"] -ClientSecret $cfg["MsClientSecret"]
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($t in (Get-XdrDiscoveryTable)) {
        $results.Add((Get-XdrTableState -Token $token -Table $t))
    }
    $view = @($results | ForEach-Object {
        [pscustomobject]@{ Table = $_.Name; Result = $(if ($_.State -eq "absent") { "absent" } elseif ($_.State -eq "empty") { "empty" } else { "rows" }); Rows = $_.Rows }
    })
    Write-Host ""
    Write-Host (($view | Format-Table -AutoSize | Out-String).TrimEnd())
    $block = New-XdrTablesBlock -Results $results.ToArray() -Generated (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Set-XdrTablesBlock -Path $Path -Block $block
    Write-Host ""
    Write-Host "  Written to $Path (XdrTables block). The agent does not read it." -ForegroundColor Green
    Write-Host "  $RerunNote"
    return $results.ToArray()
}

# Run only when executed, not when dot-sourced (tests dot-source this file).
if ($MyInvocation.InvocationName -ne ".") {
    try {
        $null = Invoke-XdrTableDiscovery -Path $ConfigFile
        exit 0
    } catch {
        Write-Warning "XDR table discovery failed: $($_.Exception.Message)"
        Write-Warning "The config file was not changed. $RerunNote"
        exit 1
    }
}
