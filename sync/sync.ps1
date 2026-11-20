param(
    [string] $SourcePath
)

$ErrorActionPreference = 'Stop'
$sourceUrl = 'https://github.com/rurewa/imfua.git'
$destination = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
if (-not $SourcePath) {
    $SourcePath = Join-Path (Split-Path -Parent $destination) 'imfua-sync-source'
}
$sourceParent = (Resolve-Path -LiteralPath (Split-Path -Parent ([IO.Path]::GetFullPath($SourcePath)))).ProviderPath
$source = Join-Path $sourceParent ([IO.Path]::GetFileName([IO.Path]::GetFullPath($SourcePath)))

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) {
        throw "Git exited with code $LASTEXITCODE."
    }
}

function Test-PathWithin([string] $Path, [string] $Directory) {
    $separator = [IO.Path]::DirectorySeparatorChar
    $prefix = $Directory.TrimEnd($separator) + $separator
    return ($Path.TrimEnd($separator) + $separator).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoLinks([string] $Directory, [bool] $IsRoot) {
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($IsRoot -and $item.Name -in '.git', 'sync') {
            continue
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Destination contains a symbolic link or junction: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            Assert-NoLinks $item.FullName $false
        }
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $destination '.git') -PathType Container)) {
    throw 'The destination must be its own Git repository.'
}
if ((Test-PathWithin $source $destination) -or (Test-PathWithin $destination $source)) {
    throw 'Use separate source and destination directories.'
}
if (-not (Test-Path -LiteralPath $source)) {
    Invoke-Git clone --branch main --single-branch --config core.autocrlf=false $sourceUrl $source
}
if ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Use a source directory without a symbolic link or junction.'
}
if (-not (Test-Path -LiteralPath (Join-Path $source '.git') -PathType Container)) {
    throw 'The source must be a dedicated clone.'
}
if ((Invoke-Git -C $source remote get-url origin) -ne $sourceUrl) {
    throw 'Unexpected source origin.'
}
if ((Invoke-Git -C $source branch --show-current) -ne 'main') {
    throw 'The source must be on main.'
}
if (Invoke-Git -C $source status --porcelain --untracked-files=no) {
    throw 'The source has local changes.'
}

Invoke-Git -C $source pull --ff-only origin main
$revision = Invoke-Git -C $source rev-parse HEAD
if ($revision -ne (Invoke-Git -C $source rev-parse refs/remotes/origin/main)) {
    throw 'The source contains local commits.'
}
if ((Invoke-Git -C $source ls-tree --name-only HEAD) -match '^(sync|\.git)$') {
    throw 'The source uses a path reserved in the destination.'
}
if ((Invoke-Git -C $source ls-tree -r HEAD) -match '^(120000|160000) ') {
    throw 'The source includes symbolic links or submodules.'
}
Assert-NoLinks $destination $true

$archive = [IO.Path]::GetTempFileName()
try {
    Invoke-Git -C $source archive --format=tar "--output=$archive" HEAD
    & tar -xf $archive -C $destination
    if ($LASTEXITCODE -ne 0) {
        throw "tar exited with code $LASTEXITCODE."
    }
}
finally {
    [IO.File]::Delete($archive)
}
"Source commit: $revision"
"Destination: $destination"
