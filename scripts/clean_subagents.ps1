[CmdletBinding()]
param(
    [ValidateSet('Discover', 'Audit', 'Canary', 'Apply')]
    [string]$Mode = 'Discover',

    [string[]]$RootThreadId,

    [string]$ManifestPath,

    [string]$CodexHome,

    [string]$StateDb,

    [switch]$ConfirmPermanentDeletion,

    [ValidateRange(1, 100)]
    [int]$Top = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$inventoryScript = Join-Path $scriptRoot 'inventory_subagents.py'
$pythonCommand = Get-Command python -ErrorAction Stop
$pythonExecutable = if ($pythonCommand.Path) { $pythonCommand.Path } else { $pythonCommand.Definition }

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded)
}

function Get-ResolvedCodexHome {
    param([string]$RequestedPath)
    if ($RequestedPath) {
        return Resolve-FullPath $RequestedPath
    }
    if ($env:CODEX_HOME) {
        return Resolve-FullPath $env:CODEX_HOME
    }
    if (-not $env:USERPROFILE) {
        throw 'Cannot resolve the default Codex home because USERPROFILE is not set.'
    }
    return Resolve-FullPath (Join-Path $env:USERPROFILE '.codex')
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TiB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KiB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-SignedBytes {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return ('-' + (Format-Bytes ([Math]::Abs($Bytes)))) }
    return ('+' + (Format-Bytes $Bytes))
}

function Format-Title {
    param([string]$Title)
    $singleLine = (($Title -replace '\s+', ' ').Trim())
    if ($singleLine.Length -le 160) { return $singleLine }
    return ($singleLine.Substring(0, 157) + '...')
}

function Invoke-Inventory {
    param(
        [Parameter(Mandatory)][string]$ResolvedCodexHome,
        [string]$ResolvedStateDb,
        [string[]]$RootIds,
        [switch]$ListRoots,
        [string[]]$CheckIds
    )

    $arguments = @($inventoryScript, '--codex-home', $ResolvedCodexHome)
    if ($ResolvedStateDb) {
        $arguments += @('--state-db', $ResolvedStateDb)
    }
    if ($ListRoots) {
        $arguments += '--list-roots'
    }
    else {
        foreach ($rootId in @($RootIds)) {
            $arguments += @('--root-thread-id', $rootId)
        }
    }
    if ($CheckIds -and $CheckIds.Count -gt 0) {
        $arguments += '--check-stdin'
        $checkJson = ConvertTo-Json -Compress -InputObject @($CheckIds)
        $raw = $checkJson | & $pythonExecutable @arguments
    }
    else {
        $raw = & $pythonExecutable @arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Read-only Codex inventory failed with exit code $LASTEXITCODE."
    }
    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Get-ScopeHash {
    param([Parameter(Mandatory)]$Manifest)
    $rootIds = @($Manifest.roots | ForEach-Object { [string]$_.id } | Sort-Object)
    $targetIds = @($Manifest.targets | ForEach-Object { [string]$_.id } | Sort-Object)
    $canonical = @(
        'codex-clean-subagents-manifest-v1'
        [string]$Manifest.codex_home
        [string]$Manifest.state_db
        ($rootIds -join ',')
        ($targetIds -join ',')
    ) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Save-Manifest {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )
    $Manifest.scope_sha256 = Get-ScopeHash $Manifest
    $resolvedPath = Resolve-FullPath $Path
    $parent = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $temporaryPath = "$resolvedPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            ($Manifest | ConvertTo-Json -Depth 10),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $resolvedPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    return $resolvedPath
}

function Load-Manifest {
    param([Parameter(Mandatory)][string]$Path)
    $resolvedPath = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Manifest does not exist: $resolvedPath"
    }
    $manifest = Get-Content -Raw -LiteralPath $resolvedPath | ConvertFrom-Json
    if ([int]$manifest.manifest_version -ne 1) {
        throw "Unsupported cleanup manifest version: $($manifest.manifest_version)"
    }
    $expectedHash = Get-ScopeHash $manifest
    if ([string]$manifest.scope_sha256 -cne $expectedHash) {
        throw 'Manifest scope hash mismatch. Run a fresh audit instead of editing the manifest.'
    }
    return [pscustomobject]@{ Path = $resolvedPath; Data = $manifest }
}

function Get-PrefixSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Length
    )
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $share
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $remaining = $Length
        $buffer = [byte[]]::new(4MB)
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $requested)
            if ($read -le 0) {
                throw "Unexpected end of file while hashing $Path"
            }
            $null = $sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $remaining -= $read
        }
        $empty = [byte[]]::new(0)
        $null = $sha.TransformFinalBlock($empty, 0, 0)
        return (([BitConverter]::ToString($sha.Hash)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-RootSnapshots {
    param([Parameter(Mandatory)]$Roots)
    $snapshots = @()
    foreach ($root in @($Roots)) {
        if (-not $root.file_exists -or -not $root.rollout_path) {
            throw "Main rollout is unavailable for root $($root.id): $($root.rollout_path)"
        }
        $item = Get-Item -LiteralPath $root.rollout_path
        $length = [long]$item.Length
        $snapshots += [pscustomobject]@{
            id = [string]$root.id
            path = [string]$item.FullName
            length = $length
            prefix_sha256 = Get-PrefixSha256 -Path $item.FullName -Length $length
        }
    }
    return $snapshots
}

function Assert-RootSnapshots {
    param(
        [Parameter(Mandatory)]$Snapshots,
        [Parameter(Mandatory)]$CurrentRoots
    )
    $currentById = @{}
    foreach ($root in @($CurrentRoots)) { $currentById[[string]$root.id] = $root }
    foreach ($snapshot in @($Snapshots)) {
        if (-not $currentById.ContainsKey($snapshot.id)) {
            throw "Main-thread database row disappeared: $($snapshot.id)"
        }
        $currentRoot = $currentById[$snapshot.id]
        $currentPath = Resolve-FullPath ([string]$currentRoot.rollout_path)
        if ($currentPath -cne (Resolve-FullPath ([string]$snapshot.path))) {
            throw "Main rollout path changed for $($snapshot.id)"
        }
        if (-not (Test-Path -LiteralPath $snapshot.path -PathType Leaf)) {
            throw "Main rollout disappeared: $($snapshot.path)"
        }
        $currentLength = [long](Get-Item -LiteralPath $snapshot.path).Length
        if ($currentLength -lt [long]$snapshot.length) {
            throw "Main rollout was truncated: $($snapshot.id)"
        }
        $currentPrefix = Get-PrefixSha256 -Path $snapshot.path -Length ([long]$snapshot.length)
        if ($currentPrefix -cne [string]$snapshot.prefix_sha256) {
            throw "Existing bytes changed in main rollout: $($snapshot.id)"
        }
    }
}

function Assert-CodexDeleteSupport {
    $codexCommand = Get-Command codex -ErrorAction Stop
    $executable = if ($codexCommand.Path) { $codexCommand.Path } else { $codexCommand.Definition }
    $helpText = (& $executable delete --help 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $helpText -notmatch '(?m)--force') {
        throw 'The installed Codex CLI does not expose the expected delete --force command.'
    }
    return $executable
}

function Invoke-CodexDelete {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$ThreadId
    )
    $lastOutput = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lastOutput = (& $Executable delete --force $ThreadId 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 250 }
    }
    throw "codex delete failed for $ThreadId after 3 attempts: $lastOutput"
}

function Get-FreeBytes {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    return [long]$item.PSDrive.Free
}

function Assert-ChecksEligible {
    param(
        [Parameter(Mandatory)]$Checks,
        [Parameter(Mandatory)]$Targets
    )
    $checksById = @{}
    foreach ($check in @($Checks)) { $checksById[[string]$check.id] = $check }
    foreach ($target in @($Targets)) {
        $id = [string]$target.id
        if (-not $checksById.ContainsKey($id)) {
            throw "Missing eligibility result for $id"
        }
        $check = $checksById[$id]
        if (-not $check.eligible_closed_leaf) {
            throw "Target is no longer an eligible closed leaf: $id"
        }
        $auditedPath = if ($target.rollout_path) { Resolve-FullPath ([string]$target.rollout_path) } else { $null }
        $currentPath = if ($check.rollout_path) { Resolve-FullPath ([string]$check.rollout_path) } else { $null }
        if ($auditedPath -cne $currentPath) {
            throw "Rollout path changed for target $id"
        }
    }
}

function Assert-DeletedChecks {
    param(
        [Parameter(Mandatory)]$Checks,
        [Parameter(Mandatory)]$Targets
    )
    $targetsById = @{}
    foreach ($target in @($Targets)) { $targetsById[[string]$target.id] = $target }
    foreach ($check in @($Checks)) {
        if ($check.thread_present -or
            [int]$check.incoming_edge_count -ne 0 -or
            [int]$check.outgoing_edge_count -ne 0) {
            throw "Deletion verification failed for $($check.id)"
        }
        $target = $targetsById[[string]$check.id]
        if ($target.rollout_path -and (Test-Path -LiteralPath ([string]$target.rollout_path))) {
            throw "Deleted subagent rollout file still exists: $($target.rollout_path)"
        }
    }
}

if ($Mode -eq 'Discover') {
    $resolvedCodexHome = Get-ResolvedCodexHome $CodexHome
    $resolvedStateDb = if ($StateDb) { Resolve-FullPath $StateDb } else { $null }
    $inventory = Invoke-Inventory -ResolvedCodexHome $resolvedCodexHome `
        -ResolvedStateDb $resolvedStateDb -ListRoots
    Write-Output 'Read-only discovery; no Codex state was changed.'
    Write-Output "State database: $($inventory.state_db)"
    $candidates = @($inventory.root_candidates | Select-Object -First $Top)
    if ($candidates.Count -eq 0) {
        Write-Output 'No main threads with eligible closed leaf subagents were found.'
        return
    }
    foreach ($root in $candidates) {
        Write-Output ('{0} | {1} | {2} eligible | {3} | {4}' -f `
            $root.id,
            (Format-Bytes ([long]$root.eligible_closed_leaf_bytes)),
            $root.eligible_closed_leaf_count,
            ($(if ($root.archived) { 'archived' } else { 'active' })),
            (Format-Title ([string]$root.title)))
    }
    return
}

if ($Mode -eq 'Audit') {
    if (-not $RootThreadId -or $RootThreadId.Count -eq 0) {
        throw 'Audit requires at least one exact -RootThreadId UUID.'
    }
    foreach ($rootId in @($RootThreadId)) {
        $parsedGuid = [Guid]::Empty
        if (-not [Guid]::TryParse($rootId, [ref]$parsedGuid)) {
            throw "RootThreadId is not a UUID: $rootId"
        }
    }
    $resolvedCodexHome = Get-ResolvedCodexHome $CodexHome
    $resolvedStateDb = if ($StateDb) { Resolve-FullPath $StateDb } else { $null }
    $inventory = Invoke-Inventory -ResolvedCodexHome $resolvedCodexHome `
        -ResolvedStateDb $resolvedStateDb -RootIds $RootThreadId

    $targets = @()
    foreach ($target in @($inventory.targets)) {
        $targets += [pscustomobject]@{
            id = [string]$target.id
            rollout_path = $target.rollout_path
            bytes = [long]$target.bytes
            existed_at_audit = [bool]$target.file_exists
            root_ids = @($target.root_ids)
            status = 'pending'
            deleted_at_utc = $null
            last_error = $null
        }
    }
    $manifest = [pscustomobject]@{
        manifest_version = 1
        created_at_utc = [DateTime]::UtcNow.ToString('o')
        codex_home = [string]$inventory.codex_home
        state_db = [string]$inventory.state_db
        roots = @($inventory.roots | ForEach-Object {
            [pscustomobject]@{ id = [string]$_.id; title = [string]$_.title }
        })
        targets = $targets
        scope_sha256 = ''
    }
    if (-not $ManifestPath) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $ManifestPath = Join-Path ([IO.Path]::GetTempPath()) "codex-subagents-audit-$stamp.json"
    }
    $savedManifest = Save-Manifest -Manifest $manifest -Path $ManifestPath

    Write-Output 'Read-only Codex audit completed. Only the audit manifest was written.'
    foreach ($root in @($inventory.roots)) {
        Write-Output ('ROOT {0} | {1} eligible ({2}) | {3} open/nonclosed excluded | {4} nonleaf excluded | {5}' -f `
            $root.id,
            $root.eligible_closed_leaf_count,
            (Format-Bytes ([long]$root.eligible_closed_leaf_bytes)),
            $root.open_or_nonclosed_subagents,
            $root.nonleaf_subagents,
            (Format-Title ([string]$root.title)))
    }
    $totalBytes = [long](($targets | Measure-Object -Property bytes -Sum).Sum)
    Write-Output "FROZEN SCOPE: $($targets.Count) closed leaf subagents, $(Format-Bytes $totalBytes)"
    foreach ($target in @($targets | Sort-Object bytes -Descending | Select-Object -First $Top)) {
        Write-Output ("  {0} | {1} | {2}" -f $target.id, (Format-Bytes $target.bytes), $target.rollout_path)
    }
    Write-Output "MANIFEST: $savedManifest"
    Write-Output 'No deletion was performed. Obtain explicit approval before Canary.'
    return
}

if (-not $ManifestPath) {
    throw "$Mode requires -ManifestPath from a completed Audit."
}
if (-not $ConfirmPermanentDeletion) {
    throw "$Mode is permanent and requires -ConfirmPermanentDeletion."
}

$loadedManifest = Load-Manifest $ManifestPath
$manifestPathResolved = $loadedManifest.Path
$manifest = $loadedManifest.Data
$requestedCodexHome = if ($CodexHome) { $CodexHome } else { [string]$manifest.codex_home }
$resolvedCodexHome = Get-ResolvedCodexHome $requestedCodexHome
if ((Resolve-FullPath $resolvedCodexHome) -cne (Resolve-FullPath ([string]$manifest.codex_home))) {
    throw 'Codex home does not match the audited manifest.'
}
$resolvedStateDb = if ($StateDb) { Resolve-FullPath $StateDb } else { Resolve-FullPath ([string]$manifest.state_db) }
if ($resolvedStateDb -cne (Resolve-FullPath ([string]$manifest.state_db))) {
    throw 'State database does not match the audited manifest.'
}

$rootIds = @($manifest.roots | ForEach-Object { [string]$_.id })
$pendingTargets = @($manifest.targets | Where-Object { $_.status -eq 'pending' })
if ($pendingTargets.Count -eq 0) {
    Write-Output 'The manifest has no pending targets.'
    return
}

if ($Mode -eq 'Canary') {
    if (@($manifest.targets | Where-Object { $_.status -eq 'deleted_canary' }).Count -gt 0) {
        throw 'This manifest already contains a completed canary.'
    }
    $existing = @($pendingTargets | Where-Object { $_.existed_at_audit } | Sort-Object bytes, id)
    $selectedTargets = if ($existing.Count -gt 0) { @($existing[0]) } else { @($pendingTargets | Sort-Object bytes, id | Select-Object -First 1) }
}
else {
    if (@($manifest.targets | Where-Object { $_.status -eq 'deleted_canary' }).Count -eq 0) {
        throw 'Apply requires a verified canary in this exact manifest.'
    }
    if (@($manifest.targets | Where-Object { $_.status -like 'delete_*' }).Count -gt 0) {
        throw 'The manifest contains an unverified or failed deletion. Inspect it and run a fresh audit.'
    }
    $selectedTargets = $pendingTargets
}

$selectedIds = @($selectedTargets | ForEach-Object { [string]$_.id })
$preInventory = Invoke-Inventory -ResolvedCodexHome $resolvedCodexHome `
    -ResolvedStateDb $resolvedStateDb -RootIds $rootIds -CheckIds $selectedIds
Assert-ChecksEligible -Checks $preInventory.checks -Targets $selectedTargets
$rootSnapshots = Get-RootSnapshots -Roots $preInventory.roots
$codexExecutable = Assert-CodexDeleteSupport
$freeBefore = Get-FreeBytes $resolvedCodexHome
$logicalBytes = [long](($selectedTargets | Measure-Object -Property bytes -Sum).Sum)
$deletedIds = [Collections.Generic.List[string]]::new()

Write-Output ("PERMANENT {0}: deleting {1} frozen closed leaf subagent(s), {2}." -f `
    $Mode.ToUpperInvariant(), $selectedTargets.Count, (Format-Bytes $logicalBytes))
if ($Mode -eq 'Canary') {
    Write-Output "Canary target: $($selectedIds[0])"
}

foreach ($target in $selectedTargets) {
    try {
        Invoke-CodexDelete -Executable $codexExecutable -ThreadId ([string]$target.id)
        $target.status = 'delete_command_succeeded'
        $target.deleted_at_utc = [DateTime]::UtcNow.ToString('o')
        $deletedIds.Add([string]$target.id)
        if (($deletedIds.Count % 50) -eq 0) {
            Save-Manifest -Manifest $manifest -Path $manifestPathResolved | Out-Null
            Write-Output "Progress: $($deletedIds.Count)/$($selectedTargets.Count)"
        }
    }
    catch {
        $target.status = 'delete_failed'
        $target.last_error = $_.Exception.Message
        Save-Manifest -Manifest $manifest -Path $manifestPathResolved | Out-Null
        throw "Stopped after $($deletedIds.Count) successful delete command(s). $($_.Exception.Message)"
    }
}
Save-Manifest -Manifest $manifest -Path $manifestPathResolved | Out-Null

$postInventory = Invoke-Inventory -ResolvedCodexHome $resolvedCodexHome `
    -ResolvedStateDb $resolvedStateDb -RootIds $rootIds -CheckIds $deletedIds.ToArray()
Assert-DeletedChecks -Checks $postInventory.checks -Targets $selectedTargets
Assert-RootSnapshots -Snapshots $rootSnapshots -CurrentRoots $postInventory.roots

$finalStatus = if ($Mode -eq 'Canary') { 'deleted_canary' } else { 'deleted_batch' }
foreach ($target in $selectedTargets) {
    $target.status = $finalStatus
    $target.last_error = $null
}
Save-Manifest -Manifest $manifest -Path $manifestPathResolved | Out-Null
$freeAfter = Get-FreeBytes $resolvedCodexHome

Write-Output ("SUCCESS: {0} subagent(s) permanently deleted; logical rollout size {1}; free-space change {2}." -f `
    $deletedIds.Count,
    (Format-Bytes $logicalBytes),
    (Format-SignedBytes ($freeAfter - $freeBefore)))
Write-Output "Main thread rows and original rollout prefixes verified: $($rootIds -join ', ')"
Write-Output "Manifest updated: $manifestPathResolved"
if ($Mode -eq 'Canary') {
    Write-Output 'Obtain separate explicit approval before Apply.'
}
