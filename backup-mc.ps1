# --- CONFIGURACOES ---
param(
    [switch]$IgnoreLock
)

$script:IsWindowsFlag = $true
$__isWindowsVar = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
if ($__isWindowsVar) {
    $script:IsWindowsFlag = [bool]$__isWindowsVar.Value
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }
try {
    if (-not $PSDefaultParameterValues) { $PSDefaultParameterValues = @{} }
    $PSDefaultParameterValues['*:Encoding'] = 'utf8'
} catch { }

. (Join-Path $PSScriptRoot 'modules\utils.ps1')
. (Join-Path $PSScriptRoot 'modules\config.ps1')
. (Join-Path $PSScriptRoot 'modules\logging.ps1')
. (Join-Path $PSScriptRoot 'modules\discord.ps1')
. (Join-Path $PSScriptRoot 'modules\rclone.ps1')
. (Join-Path $PSScriptRoot 'modules\sevenzip.ps1')

$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$Config = Get-Config -Path $ConfigPath

if (-not $Config.source) {
    throw "Config invalido: 'source' e obrigatorio."
}
if ([string]::IsNullOrWhiteSpace($Config.source.remote) -and [string]::IsNullOrWhiteSpace($Config.source.localPath)) {
    throw "Config invalido: 'source.remote' (SFTP) ou 'source.localPath' (local) e obrigatorio."
}
if (-not $Config.work -or [string]::IsNullOrWhiteSpace($Config.work.tempDir)) {
    throw "Config invalido: 'work.tempDir' e obrigatorio."
}
if (-not $Config.destination -or [string]::IsNullOrWhiteSpace($Config.destination.provider)) {
    throw "Config invalido: 'destination.provider' e obrigatorio (b2|gdrive|s3)."
}

$DestinationProvider = ($Config.destination.provider.ToString().Trim().ToLowerInvariant())
if ($DestinationProvider -notin @('b2','gdrive','s3')) {
    throw "Config invalido: destination.provider='$DestinationProvider' nao e suportado (b2|gdrive|s3)."
}

$SourceIsLocal = $false
$LocalSourcePath = $null
$RemoteSFTP = $null
if (-not [string]::IsNullOrWhiteSpace($Config.source.localPath)) {
    $SourceIsLocal = $true
    $LocalSourcePath = $Config.source.localPath
} else {
    $RemoteSFTP = ConvertTo-RcloneRemote -Remote $Config.source.remote
}
$SourceText = if ($SourceIsLocal) { $LocalSourcePath } else { $RemoteSFTP }
$PastaTemp = $Config.work.tempDir
$SyncDirName = if ($Config.work.syncDirName) { $Config.work.syncDirName } else { 'sync_dir' }
$LocalArchiveDir = if ($Config.work.localArchiveDir) { $Config.work.localArchiveDir } else { (Join-Path $PastaTemp 'archives') }

if (-not $Config.retention) {
    throw "Config invalido: 'retention' e obrigatorio."
}

$RetentionLocalKeep = 0
if ($null -ne $Config.retention.localKeep) { $RetentionLocalKeep = [int]$Config.retention.localKeep }

if ($null -eq $Config.retention.remoteKeep) {
    throw "Config invalido: 'retention.remoteKeep' e obrigatorio (0 para desativar upload)."
}
$RetentionRemoteKeep = [int]$Config.retention.remoteKeep

if ($RetentionLocalKeep -lt 0 -or $RetentionRemoteKeep -lt 0) {
    throw "Config invalido: retention.localKeep/remoteKeep nao podem ser negativos."
}
if ($RetentionLocalKeep -eq 0 -and $RetentionRemoteKeep -eq 0) {
    throw "Config invalido: retention.localKeep=0 e retention.remoteKeep=0 resultariam em nenhum backup salvo (nem local, nem remoto)."
}

$ZipCompression = if ($Config.zip -and $null -ne $Config.zip.compression) { [int]$Config.zip.compression } else { 2 }
$SkipZipTest = $false
if ($Config.zip -and $null -ne $Config.zip.skipTest) { $SkipZipTest = [bool]$Config.zip.skipTest }

$SevenZipWindowsPath = $null
$SevenZipLinuxCommand = $null
if ($Config.dependencies -and $Config.dependencies.sevenZip) {
    if ($Config.dependencies.sevenZip.windowsPath) { $SevenZipWindowsPath = $Config.dependencies.sevenZip.windowsPath }
    if ($Config.dependencies.sevenZip.linuxCommand) { $SevenZipLinuxCommand = $Config.dependencies.sevenZip.linuxCommand }
}
if ($script:IsWindowsFlag) {
    if ([string]::IsNullOrWhiteSpace($SevenZipWindowsPath)) {
        $SevenZipWindowsPath = 'C:\\Program Files\\7-Zip\\7z.exe'
    }
    $script:SevenZipExe = $SevenZipWindowsPath
} else {
    if ([string]::IsNullOrWhiteSpace($SevenZipLinuxCommand)) { $SevenZipLinuxCommand = '7z' }
    $script:SevenZipExe = $SevenZipLinuxCommand
}

$Data = Get-Date -Format "yyyy-MM-dd_HH-mm"
$NomeArquivo = "backup_minecraft_$Data.zip"

$ZipLocalPath = Join-Path $PastaTemp $NomeArquivo
$ZipArchivePath = Join-Path $LocalArchiveDir $NomeArquivo
$ZipWorkPath = $null
$KeepLocalZip = ($RetentionLocalKeep -gt 0)
$ZipWorkPath = if ($KeepLocalZip) { $ZipArchivePath } else { $ZipLocalPath }
$LogDir = Join-Path $PastaTemp 'logs'
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogPath = Join-Path $LogDir ("backup_minecraft_{0}.log" -f $Data)

$global:HeartbeatStatePath = Join-Path $LogDir ("heartbeat_{0}.json" -f $Data)

function Get-DestinationFolder {
    param(
        [Parameter(Mandatory=$true)][object]$Cfg,
        [Parameter(Mandatory=$true)][string]$Provider
    )

    switch ($Provider) {
        'b2' {
            if (-not $Cfg.destination.b2) { throw "Config invalido: 'destination.b2' e obrigatorio quando provider=b2." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.b2.remote)) { throw "Config invalido: 'destination.b2.remote' e obrigatorio." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.b2.bucket)) { throw "Config invalido: 'destination.b2.bucket' e obrigatorio (necessario para keys restritas a um bucket)." }
            $remote = ConvertTo-RcloneRemote -Remote $Cfg.destination.b2.remote
            $bucket = ConvertTo-RcloneSubPath -SubPath $Cfg.destination.b2.bucket
            $prefix = $null
            if ($Cfg.destination.b2.prefix) { $prefix = ConvertTo-RcloneSubPath -SubPath $Cfg.destination.b2.prefix }
            $sub = if ([string]::IsNullOrWhiteSpace($prefix)) { $bucket } else { "$bucket/$prefix" }
            return (Join-RcloneRemotePath -Remote $remote -SubPath $sub)
        }
        'gdrive' {
            if (-not $Cfg.destination.gdrive) { throw "Config invalido: 'destination.gdrive' e obrigatorio quando provider=gdrive." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.gdrive.remote)) { throw "Config invalido: 'destination.gdrive.remote' e obrigatorio." }
            $remote = ConvertTo-RcloneRemote -Remote $Cfg.destination.gdrive.remote
            $folder = if ($Cfg.destination.gdrive.folder) { $Cfg.destination.gdrive.folder } else { '' }
            return (Join-RcloneRemotePath -Remote $remote -SubPath $folder)
        }
        's3' {
            if (-not $Cfg.destination.s3) { throw "Config invalido: 'destination.s3' e obrigatorio quando provider=s3." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.s3.remote)) { throw "Config invalido: 'destination.s3.remote' e obrigatorio." }
            $remote = ConvertTo-RcloneRemote -Remote $Cfg.destination.s3.remote
            $bucket = $null
            if ($Cfg.destination.s3.bucket) { $bucket = ConvertTo-RcloneSubPath -SubPath $Cfg.destination.s3.bucket }
            $prefix = $null
            if ($Cfg.destination.s3.prefix) { $prefix = ConvertTo-RcloneSubPath -SubPath $Cfg.destination.s3.prefix }
            if (-not [string]::IsNullOrWhiteSpace($bucket)) {
                $sub = if ([string]::IsNullOrWhiteSpace($prefix)) { $bucket } else { "$bucket/$prefix" }
                return (Join-RcloneRemotePath -Remote $remote -SubPath $sub)
            }
            return (Join-RcloneRemotePath -Remote $remote -SubPath $prefix)
        }
        default {
            throw "Provider nao suportado: $Provider"
        }
    }
}
$DestinationFolder = Get-DestinationFolder -Cfg $Config -Provider $DestinationProvider

function ConvertTo-HumanBytes {
    param([Parameter(Mandatory=$true)][Int64]$Bytes)

    if ($Bytes -lt 0) { return "$Bytes bytes" }
    $units = @('bytes','KiB','MiB','GiB','TiB','PiB')
    [double]$value = [double]$Bytes
    $u = 0
    while ($value -ge 1024 -and $u -lt ($units.Count - 1)) {
        $value = $value / 1024
        $u++
    }
    if ($u -eq 0) { return ("{0:N0} {1}" -f $value, $units[$u]) }
    return ("{0:N2} {1}" -f $value, $units[$u])
}

function Get-FreeSpaceTextShortForPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $di = New-Object System.IO.DriveInfo($root)
            if ($di -and $di.IsReady) {
                return ("{0} free" -f (ConvertTo-HumanBytes -Bytes ([int64]$di.AvailableFreeSpace)))
            }
        }
    } catch { }

    try {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)
        $best = $null
        $bestLen = -1
        foreach ($d in $drives) {
            $dRoot = [string]$d.Root
            if ([string]::IsNullOrWhiteSpace($dRoot)) { continue }
            if ($Path.StartsWith($dRoot, [StringComparison]::OrdinalIgnoreCase)) {
                if ($dRoot.Length -gt $bestLen) {
                    $bestLen = $dRoot.Length
                    $best = $d
                }
            }
        }
        if ($best -and $best.Free -ge 0) {
            return ("{0} free" -f (ConvertTo-HumanBytes -Bytes ([int64]$best.Free)))
        }
    } catch { }

    return ''
}

$script:ExitCode = 0
$script:CreatedLock = $false

$ExitCodes = @{
    Success    = 0
    Unknown    = 1
    Lock       = 2
    Cancelled  = 4
    Dependency = 3
    Rclone     = 10
    Zip        = 11
}

# --- PROCESSO ---
if ($SourceIsLocal) {
    Write-Host "Iniciando backup via source local (sem sync)..." -ForegroundColor Cyan
} else {
    Write-Host "Iniciando backup via SFTP..." -ForegroundColor Cyan
}

$DiscordSettings = Get-DiscordSettings -Cfg $Config
Initialize-DiscordState -Discord $DiscordSettings
$script:BackupStartAt = Get-Date
$script:DiscordCurrentStep = 'init'

try { Update-DiscordHeartbeatState -Step 'init' -BackupLogPath $LogPath } catch { }

$heartbeatTimer = $null
if ($DiscordSettings.Enabled) {
    $heartbeatTimer = Start-DiscordHeartbeatTimer -Discord $DiscordSettings -BackupLogPath $LogPath
}

try {
    Assert-Command -Name 'rclone'
    if ($script:IsWindowsFlag) {
        Assert-Executable -Name '7-Zip' -Path $script:SevenZipExe
    } else {
        Assert-Command -Name $script:SevenZipExe
    }

    if (!(Test-Path $PastaTemp)) { New-Item -ItemType Directory -Path $PastaTemp | Out-Null }
    $SyncDir = Join-Path $PastaTemp $SyncDirName
    if (-not $SourceIsLocal) {
        if (!(Test-Path $SyncDir)) { New-Item -ItemType Directory -Path $SyncDir | Out-Null }
    }

    $LockPath = Join-Path $PastaTemp 'backup.lock'
    if (Test-Path $LockPath) {
        if ($IgnoreLock) {
            Write-Log "Lock encontrado em '$LockPath' mas IgnoreLock foi informado. Continuando mesmo assim (modo forcado)." 'WARN'
        } else {
            Stop-Backup -ExitCode $ExitCodes.Lock -Message "Execucao bloqueada: lock encontrado em '$LockPath'. Isso normalmente significa que ja existe um backup em andamento ou que a ultima execucao foi interrompida. Rodar duas copias ao mesmo tempo pode gerar ZIP incompleto e rotacao apagando backups indevidamente. Se voce tiver certeza que nao ha backup rodando, remova o arquivo lock manualmente e execute novamente."
        }
    }
    if (-not (Test-Path $LockPath)) {
        New-Item -ItemType File -Path $LockPath -Force | Out-Null
        $script:CreatedLock = $true
    }

    Write-Log "Log: $LogPath" 'INFO'
    Write-Log "Origem: $SourceText" 'INFO'
    Write-Log "Destino ($DestinationProvider): $DestinationFolder" 'INFO'
    Write-Log "ZIP local: $ZipWorkPath" 'INFO'
    Write-Log "Retencao local (archives): $RetentionLocalKeep" 'INFO'
    Write-Log "Retencao destino: $RetentionRemoteKeep" 'INFO'
    Write-Log ("Validacao do ZIP (7z t): {0}" -f ($(if ($SkipZipTest) { 'DESATIVADA' } else { 'ATIVADA' }))) 'INFO'

    if ($DiscordSettings.Enabled -and $DiscordSettings.NotifyStart) {
        $fields = @(
            @{ name = 'Origem'; value = $SourceText; inline = $true },
            @{ name = 'Host'; value = $env:COMPUTERNAME; inline = $true },
            @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        if ($RetentionRemoteKeep -gt 0) {
            $fields = @(
                @{ name = 'Origem'; value = $SourceText; inline = $true },
                @{ name = 'Destino'; value = $DestinationFolder; inline = $true },
                @{ name = 'Host'; value = $env:COMPUTERNAME; inline = $true },
                @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
        } else {
            $fields += @(
                @{ name = 'Upload'; value = 'DISABLED (retention.remoteKeep=0)'; inline = $false },
                @{ name = 'ZIP path'; value = $ZipWorkPath; inline = $false }
            )
        }
        $desc = "Iniciando backup. Vou baixar as alteracoes do servidor (SFTP) para uma pasta local, gerar um ZIP com timestamp, enviar o ZIP para o destino e aplicar retencao (remover backups antigos). Em caso de erro, consulte os logs."
        if ($SourceIsLocal) {
            $desc = "Iniciando backup. Vou gerar um ZIP com timestamp a partir da pasta local do servidor (sem sync). Em caso de erro, consulte os logs."
        }
        if ($RetentionRemoteKeep -le 0) {
            if ($SourceIsLocal) {
                $desc = "Iniciando backup. Vou gerar um ZIP com timestamp a partir da pasta local do servidor (sem sync). O upload esta desativado (retention.remoteKeep=0). Em caso de erro, consulte os logs."
            } else {
                $desc = "Iniciando backup. Vou baixar as alteracoes do servidor (SFTP) para uma pasta local e gerar um ZIP com timestamp. O upload esta desativado (retention.remoteKeep=0). Em caso de erro, consulte os logs."
            }
        }
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'start' -Title 'Backup Minecraft iniciado' -Color 'blue' -Description $desc -Fields $fields
    }

    if ($SourceIsLocal) {
        Write-Host "Sync pulado: source.localPath configurado."
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'sync'; inline = $true },
                @{ name = 'Origem'; value = $SourceText; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa sync pulada' -Color 'gray' -Description 'Source local configurado. Nao vou rodar rclone sync.' -Fields $fields
        }
    } else {
        Write-Host "Sincronizando arquivos (apenas novidades)..."
        Set-DiscordStep -Step 'sync'
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'sync'; inline = $true },
                @{ name = 'Origem'; value = $SourceText; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa sync iniciada' -Color 'gray' -Description 'Iniciando sincronizacao via rclone (SFTP -> local).' -Fields $fields
        }
        $syncArgs = @(
            'sync', $RemoteSFTP, $SyncDir,
            '--retries', '5',
            '--low-level-retries', '10',
            '--retries-sleep', '10s',
            '--sftp-concurrency', '1',
            '--sftp-chunk-size', '32k'
        )
        if ($Config.source.exclude) {
            foreach ($ex in $Config.source.exclude) {
                if (-not [string]::IsNullOrWhiteSpace($ex)) {
                    $syncArgs += @('--exclude', $ex)
                }
            }
        }
        $syncLog = Join-Path $LogDir ("rclone_sync_{0}.log" -f $Data)
        try { Update-DiscordHeartbeatState -Step 'sync' -RcloneLogPath $syncLog } catch { }
        Invoke-Rclone -MaxAttempts 3 -RcloneArgs $syncArgs -ProgressStage 'sync' -LogPath $syncLog
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'sync'; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false },
                @{ name = 'Log rclone'; value = $syncLog; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa sync concluida' -Color 'gray' -Description 'Arquivos atualizados: servidor (SFTP) -> pasta local. Se algo ficar estranho (arquivo faltando/erro de rede), veja o log do rclone.' -Fields $fields
        }
    }

    Write-Host "Compactando arquivos em $NomeArquivo..."
    Set-DiscordStep -Step 'zip'
    if ($DiscordSettings.Enabled) {
        $fields = @(
            @{ name = 'Etapa'; value = 'zip'; inline = $true },
            @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa zip iniciada' -Color 'gray' -Description 'Iniciando compactacao (7-Zip).' -Fields $fields
    }
    if ($KeepLocalZip) {
        if (!(Test-Path $LocalArchiveDir)) { New-Item -ItemType Directory -Path $LocalArchiveDir | Out-Null }
    }
    if (Test-Path $ZipWorkPath) { Remove-Item $ZipWorkPath -Force }
    $zipLog = Join-Path $LogDir ("zip_{0}.log" -f $Data)
    try { Update-DiscordHeartbeatState -Step 'zip' -ZipLogPath $zipLog } catch { }
    $zipSourcePath = if ($SourceIsLocal) { $LocalSourcePath } else { $SyncDir }
    $zipArgs = @('a','-tzip',("-mx={0}" -f $ZipCompression),$ZipWorkPath,(Join-Path $zipSourcePath '*'))
    if ($Config.source.exclude) {
        foreach ($ex in $Config.source.exclude) {
            if (-not [string]::IsNullOrWhiteSpace($ex)) {
                $zipArgs += ("-xr!{0}" -f $ex)
            }
        }
    }
    Invoke-7Zip -Args $zipArgs -ProgressStage 'zip' -LogPath $zipLog

    if ($DiscordSettings.Enabled) {
        $zipSizeText = ''
        try {
            if (Test-Path $zipLog) {
                $tail = @(Get-Content -LiteralPath $zipLog -Tail 200 -ErrorAction SilentlyContinue)
                $best = $null
                foreach ($line in $tail) {
                    if ($line -match 'Archive\s+size:\s*\d+\s*bytes\s*\(([^)]+)\)') {
                        $best = $Matches[1]
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($best)) {
                    $zipSizeText = $best
                }
            }
        } catch { }

        if ([string]::IsNullOrWhiteSpace($zipSizeText)) {
            try {
                if (Test-Path $ZipWorkPath) {
                    $len = (Get-Item $ZipWorkPath).Length
                    $zipSizeText = (ConvertTo-HumanBytes -Bytes ([int64]$len))
                }
            } catch { }
        }

        $zipFreeTextShort = Get-FreeSpaceTextShortForPath -Path $ZipWorkPath

        $fields = @(
            @{ name = 'Etapa'; value = 'zip'; inline = $true },
            @{ name = 'Arquivo'; value = $ZipWorkPath; inline = $false },
            @{ name = 'Tamanho'; value = $zipSizeText; inline = $true },
            @{ name = 'Free space'; value = $zipFreeTextShort; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa zip concluida' -Color 'gray' -Description 'ZIP gerado a partir da copia local (artefato unico para restore). Se houver corrupcao/erro, consulte o log do backup.' -Fields $fields
    }

    Write-Host "Validando integridade do ZIP..."
    if (-not $SkipZipTest) {
        Set-DiscordStep -Step 'zip_test'
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'zip_test'; inline = $true },
                @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa zip_test iniciada' -Color 'gray' -Description 'Iniciando validacao do ZIP (7z t).' -Fields $fields
        }

        Invoke-7Zip -Args @('t', $ZipWorkPath) -ProgressStage 'zip_test'
    } else {
        Write-Host "Validacao do ZIP desativada (zip.skipTest=true)." -ForegroundColor Yellow
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'zip_test'; inline = $true },
                @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa zip_test pulada' -Color 'gray' -Description 'Validacao do ZIP esta desativada (zip.skipTest=true).' -Fields $fields
        }
    }

    if ($RetentionLocalKeep -gt 0) {
        Write-Host "Verificando backups antigos localmente para manter apenas os $RetentionLocalKeep mais recentes..." -ForegroundColor Yellow
        $LocalBackupsOrdenados = @(
            Get-ChildItem -Path $LocalArchiveDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^backup_minecraft_.*\.zip$' } |
                Sort-Object -Property LastWriteTime -Descending
        )
        $LocalTotal = $LocalBackupsOrdenados.Count
        $LocalParaDeletar = @($LocalBackupsOrdenados | Select-Object -Skip $RetentionLocalKeep)
        foreach ($f in $LocalParaDeletar) {
            Write-Host "Deletando backup local antigo: $($f.Name)" -ForegroundColor Red
            if ($DiscordSettings.Enabled) {
                $fields = @(
                    @{ name = 'Retencao local'; value = "$LocalTotal encontrados / limite $RetentionLocalKeep"; inline = $false },
                    @{ name = 'Deletando'; value = $f.Name; inline = $false },
                    @{ name = 'Pasta'; value = $LocalArchiveDir; inline = $false },
                    @{ name = 'Log backup'; value = $LogPath; inline = $false }
                )
                Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Retencao local: deletando ZIP antigo' -Color 'gray' -Description $null -Fields $fields
            }
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($RetentionRemoteKeep -gt 0) {
        Write-Host "Enviando para o destino..."
        Set-DiscordStep -Step 'upload'
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'upload'; inline = $true },
                @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                @{ name = 'Destino'; value = $DestinationFolder; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa upload iniciada' -Color 'gray' -Description 'Iniciando upload via rclone.' -Fields $fields
        }
        if ($DestinationProvider -ne 'b2') {
            $mkdirLog = Join-Path $LogDir ("rclone_upload_mkdir_{0}.log" -f $Data)
            try { Update-DiscordHeartbeatState -Step 'upload' -RcloneLogPath $mkdirLog } catch { }
            Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('mkdir', $DestinationFolder) -ProgressStage 'upload' -LogPath $mkdirLog
        }
        if ($KeepLocalZip) {
            $uploadLog = Join-Path $LogDir ("rclone_upload_copy_{0}.log" -f $Data)
            try { Update-DiscordHeartbeatState -Step 'upload' -RcloneLogPath $uploadLog } catch { }
            Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('copy', $ZipWorkPath, $DestinationFolder) -ProgressStage 'upload' -LogPath $uploadLog
        } else {
            $uploadLog = Join-Path $LogDir ("rclone_upload_move_{0}.log" -f $Data)
            try { Update-DiscordHeartbeatState -Step 'upload' -RcloneLogPath $uploadLog } catch { }
            Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('move', $ZipWorkPath, $DestinationFolder) -ProgressStage 'upload' -LogPath $uploadLog
        }
        if ($DiscordSettings.Enabled) {
            $rcloneUploadLog = $uploadLog
            $fields = @(
                @{ name = 'Etapa'; value = 'upload'; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false },
                @{ name = 'Log rclone'; value = $rcloneUploadLog; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa upload concluida' -Color 'gray' -Description 'ZIP enviado para o destino configurado. Se houver falha de credenciais/permissao, veja o log do rclone.' -Fields $fields
        }
    } else {
        Write-Host "Upload para destino desativado (retention.remoteKeep=0)." -ForegroundColor Yellow
        if (-not $KeepLocalZip) {
            Write-Host "Como retention.localKeep=0 e o upload esta desativado, o ZIP sera mantido em: $ZipWorkPath" -ForegroundColor Yellow
        }
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'upload'; inline = $true },
                @{ name = 'Upload'; value = 'DISABLED (retention.remoteKeep=0)'; inline = $false },
                @{ name = 'ZIP path'; value = $ZipWorkPath; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa upload pulada' -Color 'gray' -Description 'Upload para destino esta desativado.' -Fields $fields
        }
    }

    if ($RetentionRemoteKeep -gt 0) {
        Write-Host "Verificando backups antigos no destino para manter apenas os $RetentionRemoteKeep mais recentes..." -ForegroundColor Yellow

        Set-DiscordStep -Step 'rotate'
        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'rotate'; inline = $true },
                @{ name = 'Destino'; value = $DestinationFolder; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa rotate iniciada' -Color 'gray' -Description 'Iniciando retencao no destino (listar e deletar backups antigos).' -Fields $fields
        }

        $lsl = & rclone lsl $DestinationFolder
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Stop-Backup -ExitCode $ExitCodes.Rclone -Message "Falha ao listar backups no destino para rotacao (rclone lsl exit code $code). A rotacao nao pode continuar com seguranca. Verifique permissoes e configuracao do remote no rclone."
        }
        $parsed = foreach ($line in $lsl) {
            if ($line -match '^\s*(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.+)$') {
                $name = $Matches[4]
                if ($name -match '^backup_minecraft_.*\.zip$') {
                    $whenText = "$($Matches[2]) $($Matches[3])"
                    $when = $null
                    try {
                        $when = [datetime]::Parse($whenText, [System.Globalization.CultureInfo]::InvariantCulture)
                    } catch {
                        continue
                    }
                    [pscustomobject]@{ Name = $name; When = $when }
                }
            }
        }
        $RemoteBackupsOrdenados = @($parsed | Sort-Object -Property When -Descending)

        $RemoteTotal = $RemoteBackupsOrdenados.Count

        $RemoteParaDeletar = @($RemoteBackupsOrdenados | Select-Object -Skip $RetentionRemoteKeep)
        if ($RemoteParaDeletar.Count -gt 0) {
            foreach ($b in $RemoteParaDeletar) {
                Write-Host "Deletando backup antigo no destino: $($b.Name)" -ForegroundColor Red
                if ($DiscordSettings.Enabled) {
                    $fields = @(
                        @{ name = 'Retencao destino'; value = "$RemoteTotal encontrados / limite $RetentionRemoteKeep"; inline = $false },
                        @{ name = 'Deletando'; value = $b.Name; inline = $false },
                        @{ name = 'Destino'; value = $DestinationFolder; inline = $false },
                        @{ name = 'Log backup'; value = $LogPath; inline = $false }
                    )
                    Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Retencao destino: deletando ZIP antigo' -Color 'gray' -Description $null -Fields $fields
                }
                Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('deletefile', ("{0}/{1}" -f $DestinationFolder.TrimEnd('/'), $b.Name))
            }
            Write-Host "Limpeza do destino concluida!" -ForegroundColor Green
        } else {
            Write-Host "Nenhum backup antigo para deletar no destino. Total atual: $($RemoteBackupsOrdenados.Count)." -ForegroundColor Green
        }

        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'rotate'; inline = $true },
                @{ name = 'Mantidos'; value = "$RetentionRemoteKeep"; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa rotate concluida' -Color 'gray' -Description 'Retencao aplicada no destino: backups antigos removidos (quando necessario).' -Fields $fields
        }
    }

    Write-Host "Processo de backup concluido com sucesso!" -ForegroundColor Green
    Write-Log 'Processo concluido com sucesso.' 'INFO'

    if ($DiscordSettings.Enabled -and $DiscordSettings.NotifySuccess) {
        $dur = ''
        if ($script:BackupStartAt) {
            $span = (Get-Date) - $script:BackupStartAt
            $dur = ('{0:hh\:mm\:ss}' -f $span)
        }

        $sizeText = ''
        try {
            if (Test-Path $ZipWorkPath) {
                $len = (Get-Item $ZipWorkPath).Length
                $sizeText = ("{0} ({1:N0} bytes)" -f (ConvertTo-HumanBytes -Bytes ([int64]$len)), ([int64]$len))
            }
        } catch { }

        $freeTextShort = ''
        try {
            if (-not [string]::IsNullOrWhiteSpace($ZipWorkPath)) {
                $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)
                $best = $null
                $bestLen = -1

                foreach ($d in $drives) {
                    $root = [string]$d.Root
                    if ([string]::IsNullOrWhiteSpace($root)) { continue }
                    if ($ZipWorkPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                        if ($root.Length -gt $bestLen) {
                            $bestLen = $root.Length
                            $best = $d
                        }
                    }
                }
                if ($best -and $best.Free -ge 0) {
                    $freeTextShort = ("{0} free" -f (ConvertTo-HumanBytes -Bytes ([int64]$best.Free)))
                }
            }
        } catch { }

        if ($RetentionRemoteKeep -gt 0) {
            $fields = @(
                @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                @{ name = 'Duracao'; value = $dur; inline = $true },
                @{ name = 'Tamanho'; value = $sizeText; inline = $true },
                @{ name = 'Destino'; value = $DestinationFolder; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'success' -Title 'Backup Minecraft concluido' -Color 'green' -Description $null -Fields $fields
        } else {
            $fields = @(
                @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                @{ name = 'Duracao'; value = $dur; inline = $true },
                @{ name = 'Tamanho'; value = $sizeText; inline = $true },
                @{ name = 'ZIP path'; value = $ZipWorkPath; inline = $false },
                @{ name = 'Upload'; value = 'DISABLED (retention.remoteKeep=0)'; inline = $false },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            if (-not [string]::IsNullOrWhiteSpace($freeTextShort)) {
                $fields = @(
                    @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
                    @{ name = 'Duracao'; value = $dur; inline = $true },
                    @{ name = 'Tamanho'; value = $sizeText; inline = $true },
                    @{ name = 'Free space'; value = $freeTextShort; inline = $true },
                    @{ name = 'ZIP path'; value = $ZipWorkPath; inline = $false },
                    @{ name = 'Upload'; value = 'DISABLED (retention.remoteKeep=0)'; inline = $false },
                    @{ name = 'Log backup'; value = $LogPath; inline = $false }
                )
            }
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'success' -Title 'Backup Minecraft concluido (upload disabled)' -Color 'green' -Description $null -Fields $fields
        }
    }
} catch {
    $code = $ExitCodes.Unknown
    $cancelled = $false
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        $cancelled = $true
        $code = $ExitCodes.Cancelled
    }
    if ($_.Exception -and $_.Exception.Data -and $_.Exception.Data.Contains('ExitCode')) {
        $code = [int]$_.Exception.Data['ExitCode']
    }
    $script:ExitCode = $code

    if ($cancelled) {
        Write-Log "Backup interrompido pelo usuario (Ctrl+C)." 'ERROR'
    } else {
        Write-Log "Falha no backup (exit code $code): $($_.Exception.Message)" 'ERROR'
    }
    Write-Log "Consulte o log em: $LogPath" 'ERROR'

    if ($DiscordSettings.Enabled -and $DiscordSettings.NotifyFailure) {
        $mention = $null
        if (-not $cancelled) {
            $mention = Get-DiscordMentionContentOnFailure -Discord $DiscordSettings
        }

        $dur = ''
        if ($script:BackupStartAt) {
            $span = (Get-Date) - $script:BackupStartAt
            $dur = ('{0:hh\:mm\:ss}' -f $span)
        }

        $fields = @(
            @{ name = 'Exit code'; value = "$code"; inline = $true },
            @{ name = 'Duracao'; value = $dur; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )

        $rlp = Get-Variable -Name RcloneLogPaths -Scope Script -ErrorAction SilentlyContinue
        if ($rlp -and $rlp.Value -and $rlp.Value.ContainsKey($script:DiscordCurrentStep)) {
            $fields += @(@{ name = 'Log rclone'; value = [string]$rlp.Value[$script:DiscordCurrentStep]; inline = $false })
        }

        $title = if ($cancelled) { 'Backup Minecraft interrompido' } else { 'Backup Minecraft falhou' }
        $descText = if ($cancelled) { 'Execucao interrompida pelo usuario (Ctrl+C) ou encerramento do terminal.' } else { $($_.Exception.Message) }

        $embed = New-DiscordEmbed -Title $title -Color 'red' -Description (ConvertTo-DiscordTextTruncated -Text $descText -MaxLength 1000) -Fields $fields
        $payload = @{ embeds = @($embed) }

        if (-not [string]::IsNullOrWhiteSpace($mention)) { $payload.content = $mention }
        if (-not [string]::IsNullOrWhiteSpace($DiscordSettings.Username)) { $payload.username = $DiscordSettings.Username }
        if (-not [string]::IsNullOrWhiteSpace($DiscordSettings.AvatarUrl)) { $payload.avatar_url = $DiscordSettings.AvatarUrl }

        $ctx = if ($cancelled) { 'cancelled' } else { 'failure' }
        $url = $DiscordSettings.AlertUrl
        if ([string]::IsNullOrWhiteSpace($url)) { $url = $DiscordSettings.NormalUrl }
        Send-DiscordWebhook -Url $url -Payload $payload -Discord $DiscordSettings -Context $ctx
    }
} finally {
    Stop-DiscordHeartbeatTimer -Timer $heartbeatTimer
    $LockPath = Join-Path $PastaTemp 'backup.lock'
    if ($script:CreatedLock -and (Test-Path $LockPath)) {
        Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
    }

    exit $script:ExitCode
}