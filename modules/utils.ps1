function ConvertTo-RcloneRemote {
    param([Parameter(Mandatory=$true)][string]$Remote)
    $r = $Remote.Trim()
    $r = $r.TrimEnd('/')
    if (-not $r.EndsWith(':')) { $r += ':' }
    return $r
}

function ConvertTo-RcloneSubPath {
    param([Parameter(Mandatory=$true)][string]$SubPath)
    $p = $SubPath.Trim()
    $p = $p.Trim('/')
    return $p
}

function Join-RcloneRemotePath {
    param(
        [Parameter(Mandatory=$true)][string]$Remote,
        [Parameter(Mandatory=$false)][string]$SubPath
    )
    $r = ConvertTo-RcloneRemote -Remote $Remote
    if ([string]::IsNullOrWhiteSpace($SubPath)) { return $r }
    $p = ConvertTo-RcloneSubPath -SubPath $SubPath
    if ([string]::IsNullOrWhiteSpace($p)) { return $r }
    return ($r + $p)
}
