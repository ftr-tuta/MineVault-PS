# --- CONFIGURAÇÕES ---
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

function Get-Config {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!(Test-Path $Path)) {
        throw "Arquivo de configuração não encontrado: '$Path'. Crie um config.json (use o config.json.example como base)."
    }
    $raw = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Arquivo de configuração está vazio: '$Path'."
    }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        throw "Falha ao parsear JSON em '$Path': $($_.Exception.Message)"
    }
}

$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$Config = Get-Config -Path $ConfigPath

if (-not $Config.source -or [string]::IsNullOrWhiteSpace($Config.source.remote)) {
    throw "Config inválido: 'source.remote' é obrigatório."
}
if (-not $Config.work -or [string]::IsNullOrWhiteSpace($Config.work.tempDir)) {
    throw "Config inválido: 'work.tempDir' é obrigatório."
}
if (-not $Config.destination -or [string]::IsNullOrWhiteSpace($Config.destination.provider)) {
    throw "Config inválido: 'destination.provider' é obrigatório (b2|gdrive|s3)."
}

$DestinationProvider = ($Config.destination.provider.ToString().Trim().ToLowerInvariant())
if ($DestinationProvider -notin @('b2','gdrive','s3')) {
    throw "Config inválido: destination.provider='$DestinationProvider' não é suportado (b2|gdrive|s3)."
}

$RemoteSFTP = ConvertTo-RcloneRemote -Remote $Config.source.remote
$PastaTemp = $Config.work.tempDir
$SyncDirName = if ($Config.work.syncDirName) { $Config.work.syncDirName } else { 'sync_dir' }
$LocalArchiveDir = if ($Config.work.localArchiveDir) { $Config.work.localArchiveDir } else { (Join-Path $PastaTemp 'archives') }

if (-not $Config.retention) {
    throw "Config inválido: 'retention' é obrigatório."
}

$RetentionLocalKeep = 0
if ($null -ne $Config.retention.localKeep) { $RetentionLocalKeep = [int]$Config.retention.localKeep }

if ($null -eq $Config.retention.remoteKeep) {
    throw "Config inválido: 'retention.remoteKeep' é obrigatório (0 para desativar upload)."
}
$RetentionRemoteKeep = [int]$Config.retention.remoteKeep

if ($RetentionLocalKeep -lt 0 -or $RetentionRemoteKeep -lt 0) {
    throw "Config inválido: retention.localKeep/remoteKeep não podem ser negativos."
}
if ($RetentionLocalKeep -eq 0 -and $RetentionRemoteKeep -eq 0) {
    throw "Config inválido: retention.localKeep=0 e retention.remoteKeep=0 resultariam em nenhum backup salvo (nem local, nem remoto)."
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

function Get-DestinationFolder {
    param(
        [Parameter(Mandatory=$true)][object]$Cfg,
        [Parameter(Mandatory=$true)][string]$Provider
    )

    switch ($Provider) {
        'b2' {
            if (-not $Cfg.destination.b2) { throw "Config inválido: 'destination.b2' é obrigatório quando provider=b2." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.b2.remote)) { throw "Config inválido: 'destination.b2.remote' é obrigatório." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.b2.bucket)) { throw "Config inválido: 'destination.b2.bucket' é obrigatório (necessário para keys restritas a um bucket)." }
            $remote = ConvertTo-RcloneRemote -Remote $Cfg.destination.b2.remote
            $bucket = ConvertTo-RcloneSubPath -SubPath $Cfg.destination.b2.bucket
            $prefix = $null
            if ($Cfg.destination.b2.prefix) { $prefix = ConvertTo-RcloneSubPath -SubPath $Cfg.destination.b2.prefix }
            $sub = if ([string]::IsNullOrWhiteSpace($prefix)) { $bucket } else { "$bucket/$prefix" }
            return (Join-RcloneRemotePath -Remote $remote -SubPath $sub)
        }
        'gdrive' {
            if (-not $Cfg.destination.gdrive) { throw "Config inválido: 'destination.gdrive' é obrigatório quando provider=gdrive." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.gdrive.remote)) { throw "Config inválido: 'destination.gdrive.remote' é obrigatório." }
            $remote = ConvertTo-RcloneRemote -Remote $Cfg.destination.gdrive.remote
            $folder = if ($Cfg.destination.gdrive.folder) { $Cfg.destination.gdrive.folder } else { '' }
            return (Join-RcloneRemotePath -Remote $remote -SubPath $folder)
        }
        's3' {
            if (-not $Cfg.destination.s3) { throw "Config inválido: 'destination.s3' é obrigatório quando provider=s3." }
            if ([string]::IsNullOrWhiteSpace($Cfg.destination.s3.remote)) { throw "Config inválido: 'destination.s3.remote' é obrigatório." }
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
            throw "Provider não suportado: $Provider"
        }
    }
}

$DestinationFolder = Get-DestinationFolder -Cfg $Config -Provider $DestinationProvider

$script:ExitCode = 0
$script:CreatedLock = $false

$ExitCodes = @{
    Success    = 0
    Unknown    = 1
    Lock       = 2
    Dependency = 3
    Rclone     = 10
    Zip        = 11
}

function Stop-Backup {
    param(
        [Parameter(Mandatory=$true)][int]$ExitCode,
        [Parameter(Mandatory=$true)][string]$Message
    )
    $ex = [System.Exception]::new($Message)
    $null = $ex.Data.Add('ExitCode', $ExitCode)
    throw $ex
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $line
    if ($Level -eq 'ERROR') {
        Write-Host $Message -ForegroundColor Red
    } elseif ($Level -eq 'WARN') {
        Write-Host $Message -ForegroundColor Yellow
    } else {
        Write-Host $Message -ForegroundColor Gray
    }
}

function Assert-Executable {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Path
    )
    if (!(Test-Path $Path)) {
        Stop-Backup -ExitCode $ExitCodes.Dependency -Message "Dependência ausente: $Name não foi encontrado em '$Path'. Instale/ajuste a configuração (ex.: reinstale o 7-Zip ou corrija a variável 'Caminho7Zip'). Sem isso, o backup não pode ser compactado com segurança."
    }
}

function Assert-Command {
    param([Parameter(Mandatory=$true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Stop-Backup -ExitCode $ExitCodes.Dependency -Message "Dependência ausente: comando '$Name' não encontrado no PATH. Instale o rclone e garanta que 'rclone version' funciona no mesmo PowerShell que executa o script (incluindo no Agendador de Tarefas)."
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$ActionName,
        [Parameter(Mandatory=$true)][scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [int]$SleepSeconds = 10
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Log "$ActionName (tentativa $attempt/$MaxAttempts)" 'INFO'
            & $Action
            return
        } catch {
            Write-Log "$ActionName falhou: $($_.Exception.Message)" 'WARN'
            if ($attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Seconds $SleepSeconds
        }
    }
}

function Invoke-Rclone {
    param(
        [Parameter(Mandatory=$true)][string[]]$RcloneArgs,
        [int]$MaxAttempts = 3
    )
    $pretty = "rclone {0}" -f ($RcloneArgs -join ' ')
    Invoke-WithRetry -ActionName $pretty -MaxAttempts $MaxAttempts -Action {
        & rclone @RcloneArgs
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Stop-Backup -ExitCode $ExitCodes.Rclone -Message "Falha ao executar: $pretty (exit code $code). Causas comuns: remote não existe no 'rclone config', credenciais inválidas, permissão negada, rede instável, ou caminho remoto incorreto."
        }
    }
}

function Invoke-7Zip {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args
    )
    & $script:SevenZipExe @Args
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Stop-Backup -ExitCode $ExitCodes.Zip -Message "Falha ao executar o 7-Zip (exit code $code). Isso pode indicar arquivo em uso/permissão negada/sem espaço em disco. Verifique espaço em '$PastaTemp' e se o diretório não está travado por outro processo."
    }
}

# --- PROCESSO ---
Write-Host "Iniciando backup via SFTP..." -ForegroundColor Cyan

try {
    Assert-Command -Name 'rclone'
    if ($script:IsWindowsFlag) {
        Assert-Executable -Name '7-Zip' -Path $script:SevenZipExe
    } else {
        Assert-Command -Name $script:SevenZipExe
    }

    if (!(Test-Path $PastaTemp)) { New-Item -ItemType Directory -Path $PastaTemp | Out-Null }
    $SyncDir = Join-Path $PastaTemp $SyncDirName
    if (!(Test-Path $SyncDir)) { New-Item -ItemType Directory -Path $SyncDir | Out-Null }

    $LockPath = Join-Path $PastaTemp 'backup.lock'
    if (Test-Path $LockPath) {
        if ($IgnoreLock) {
            Write-Log "Lock encontrado em '$LockPath' mas IgnoreLock foi informado. Continuando mesmo assim (modo forçado)." 'WARN'
        } else {
            Stop-Backup -ExitCode $ExitCodes.Lock -Message "Execução bloqueada: lock encontrado em '$LockPath'. Isso normalmente significa que já existe um backup em andamento ou que a última execução foi interrompida. Rodar duas cópias ao mesmo tempo pode gerar ZIP incompleto e rotação apagando backups indevidamente. Se você tiver certeza que não há backup rodando, remova o arquivo lock manualmente e execute novamente."
        }
    }
    if (-not (Test-Path $LockPath)) {
        New-Item -ItemType File -Path $LockPath -Force | Out-Null
        $script:CreatedLock = $true
    }

    Write-Log "Log: $LogPath" 'INFO'
    Write-Log "Origem: $RemoteSFTP" 'INFO'
    Write-Log "Destino ($DestinationProvider): $DestinationFolder" 'INFO'
    Write-Log "ZIP local: $ZipWorkPath" 'INFO'
    Write-Log "Retenção local (archives): $RetentionLocalKeep" 'INFO'
    Write-Log "Retenção destino: $RetentionRemoteKeep" 'INFO'
    Write-Log ("Validação do ZIP (7z t): {0}" -f ($(if ($SkipZipTest) { 'DESATIVADA' } else { 'ATIVADA' }))) 'INFO'

    Write-Host "Sincronizando arquivos (apenas novidades)..."
    $syncArgs = @(
        'sync', $RemoteSFTP, $SyncDir,
        '--progress',
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
    Invoke-Rclone -MaxAttempts 3 -RcloneArgs $syncArgs

    Write-Host "Compactando arquivos em $NomeArquivo..."
    if ($KeepLocalZip) {
        if (!(Test-Path $LocalArchiveDir)) { New-Item -ItemType Directory -Path $LocalArchiveDir | Out-Null }
    }
    if (Test-Path $ZipWorkPath) { Remove-Item $ZipWorkPath -Force }
    Invoke-7Zip -Args @('a','-tzip',("-mx={0}" -f $ZipCompression),$ZipWorkPath,(Join-Path $SyncDir '*'))

    Write-Host "Validando integridade do ZIP..."
    if (-not $SkipZipTest) {
        Invoke-7Zip -Args @('t', $ZipWorkPath)
    } else {
        Write-Host "Validação do ZIP desativada (zip.skipTest=true)." -ForegroundColor Yellow
    }

    if ($RetentionLocalKeep -gt 0) {
        Write-Host "Verificando backups antigos localmente para manter apenas os $RetentionLocalKeep mais recentes..." -ForegroundColor Yellow
        $LocalBackupsOrdenados = @(
            Get-ChildItem -Path $LocalArchiveDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^backup_minecraft_.*\.zip$' } |
                Sort-Object -Property LastWriteTime -Descending
        )
        $LocalParaDeletar = @($LocalBackupsOrdenados | Select-Object -Skip $RetentionLocalKeep)
        foreach ($f in $LocalParaDeletar) {
            Write-Host "Deletando backup local antigo: $($f.Name)" -ForegroundColor Red
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($RetentionRemoteKeep -gt 0) {
        Write-Host "Enviando para o destino..."
        if ($DestinationProvider -ne 'b2') {
            Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('mkdir', $DestinationFolder)
        }
        if ($KeepLocalZip) {
            Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('copy', $ZipWorkPath, $DestinationFolder, '--progress')
        } else {
            Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('move', $ZipWorkPath, $DestinationFolder, '--progress')
        }
    } else {
        Write-Host "Upload para destino desativado (retention.remoteKeep=0)."
        if (-not $KeepLocalZip) {
            Write-Host "Como retention.localKeep=0 e o upload está desativado, o ZIP será mantido em: $ZipWorkPath" -ForegroundColor Yellow
        }
    }

    if ($RetentionRemoteKeep -gt 0) {
        Write-Host "Verificando backups antigos no destino para manter apenas os $RetentionRemoteKeep mais recentes..." -ForegroundColor Yellow

        $lsl = & rclone lsl $DestinationFolder
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Stop-Backup -ExitCode $ExitCodes.Rclone -Message "Falha ao listar backups no destino para rotação (rclone lsl exit code $code). A rotação não pode continuar com segurança. Verifique permissões e configuração do remote no rclone."
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

        $RemoteParaDeletar = @($RemoteBackupsOrdenados | Select-Object -Skip $RetentionRemoteKeep)
        if ($RemoteParaDeletar.Count -gt 0) {
            foreach ($b in $RemoteParaDeletar) {
                Write-Host "Deletando backup antigo no destino: $($b.Name)" -ForegroundColor Red
                Invoke-Rclone -MaxAttempts 3 -RcloneArgs @('deletefile', ("{0}/{1}" -f $DestinationFolder.TrimEnd('/'), $b.Name))
            }
            Write-Host "Limpeza do destino concluída!" -ForegroundColor Green
        } else {
            Write-Host "Nenhum backup antigo para deletar no destino. Total atual: $($RemoteBackupsOrdenados.Count)." -ForegroundColor Green
        }
    }

    Write-Host "Processo de backup concluído com sucesso!" -ForegroundColor Green
    Write-Log 'Processo concluído com sucesso.' 'INFO'
} catch {
    $code = $ExitCodes.Unknown
    if ($_.Exception -and $_.Exception.Data -and $_.Exception.Data.Contains('ExitCode')) {
        $code = [int]$_.Exception.Data['ExitCode']
    }
    $script:ExitCode = $code
    Write-Log "Falha no backup (exit code $code): $($_.Exception.Message)" 'ERROR'
    Write-Log "Consulte o log em: $LogPath" 'ERROR'
} finally {
    $LockPath = Join-Path $PastaTemp 'backup.lock'
    if ($script:CreatedLock -and (Test-Path $LockPath)) {
        Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
    }

    exit $script:ExitCode
}