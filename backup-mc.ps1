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

. (Join-Path $PSScriptRoot 'modules\utils.ps1')
. (Join-Path $PSScriptRoot 'modules\config.ps1')
. (Join-Path $PSScriptRoot 'modules\logging.ps1')
. (Join-Path $PSScriptRoot 'modules\discord.ps1')
. (Join-Path $PSScriptRoot 'modules\rclone.ps1')
. (Join-Path $PSScriptRoot 'modules\sevenzip.ps1')

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

$global:HeartbeatStatePath = Join-Path $LogDir ("heartbeat_{0}.json" -f $Data)

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
    Cancelled  = 4
    Dependency = 3
    Rclone     = 10
    Zip        = 11
}

# --- PROCESSO ---
Write-Host "Iniciando backup via SFTP..." -ForegroundColor Cyan

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

    if ($DiscordSettings.Enabled -and $DiscordSettings.NotifyStart) {
        $fields = @(
            @{ name = 'Origem'; value = $RemoteSFTP; inline = $true },
            @{ name = 'Destino'; value = $DestinationFolder; inline = $true },
            @{ name = 'Host'; value = $env:COMPUTERNAME; inline = $true },
            @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        $desc = "Iniciando backup. Vou baixar as alterações do servidor (SFTP) para uma pasta local, gerar um ZIP com timestamp, enviar o ZIP para o destino e aplicar retenção (remover backups antigos). Em caso de erro, consulte os logs."
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'start' -Title 'Backup Minecraft iniciado' -Color 'blue' -Description $desc -Fields $fields
    }

    Write-Host "Sincronizando arquivos (apenas novidades)..."
    Set-DiscordStep -Step 'sync'
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
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa sync concluída' -Color 'gray' -Description 'Arquivos atualizados: servidor (SFTP) -> pasta local. Se algo ficar estranho (arquivo faltando/erro de rede), veja o log do rclone.' -Fields $fields
    }

    Write-Host "Compactando arquivos em $NomeArquivo..."
    Set-DiscordStep -Step 'zip'
    if ($KeepLocalZip) {
        if (!(Test-Path $LocalArchiveDir)) { New-Item -ItemType Directory -Path $LocalArchiveDir | Out-Null }
    }
    if (Test-Path $ZipWorkPath) { Remove-Item $ZipWorkPath -Force }
    Invoke-7Zip -Args @('a','-tzip',("-mx={0}" -f $ZipCompression),$ZipWorkPath,(Join-Path $SyncDir '*')) -ProgressStage 'zip'

    if ($DiscordSettings.Enabled) {
        $fields = @(
            @{ name = 'Etapa'; value = 'zip'; inline = $true },
            @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa zip concluída' -Color 'gray' -Description 'ZIP gerado a partir da cópia local (artefato único para restore). Se houver corrupção/erro, consulte o log do backup.' -Fields $fields
    }

    Write-Host "Validando integridade do ZIP..."
    if (-not $SkipZipTest) {
        Set-DiscordStep -Step 'zip_test'

        Invoke-7Zip -Args @('t', $ZipWorkPath) -ProgressStage 'zip_test'
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
        Set-DiscordStep -Step 'upload'
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
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa upload concluída' -Color 'gray' -Description 'ZIP enviado para o destino configurado. Se houver falha de credenciais/permissão, veja o log do rclone.' -Fields $fields
        }
    } else {
        Write-Host "Upload para destino desativado (retention.remoteKeep=0)." -ForegroundColor Yellow
        if (-not $KeepLocalZip) {
            Write-Host "Como retention.localKeep=0 e o upload está desativado, o ZIP será mantido em: $ZipWorkPath" -ForegroundColor Yellow
        }
    }

    if ($RetentionRemoteKeep -gt 0) {
        Write-Host "Verificando backups antigos no destino para manter apenas os $RetentionRemoteKeep mais recentes..." -ForegroundColor Yellow

        Set-DiscordStep -Step 'rotate'

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

        if ($DiscordSettings.Enabled) {
            $fields = @(
                @{ name = 'Etapa'; value = 'rotate'; inline = $true },
                @{ name = 'Mantidos'; value = "$RetentionRemoteKeep"; inline = $true },
                @{ name = 'Log backup'; value = $LogPath; inline = $false }
            )
            Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'stage' -Title 'Etapa rotate concluída' -Color 'gray' -Description 'Retenção aplicada no destino: backups antigos removidos (quando necessário).' -Fields $fields
        }
    }

    Write-Host "Processo de backup concluído com sucesso!" -ForegroundColor Green
    Write-Log 'Processo concluído com sucesso.' 'INFO'

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
                $sizeText = ('{0:N0} bytes' -f $len)
            }
        } catch { }

        $fields = @(
            @{ name = 'Arquivo'; value = $NomeArquivo; inline = $true },
            @{ name = 'Duração'; value = $dur; inline = $true },
            @{ name = 'Tamanho'; value = $sizeText; inline = $true },
            @{ name = 'Destino'; value = $DestinationFolder; inline = $false },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        Send-DiscordStageEvent -Discord $DiscordSettings -Kind 'success' -Title 'Backup Minecraft concluído' -Color 'green' -Description $null -Fields $fields
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
        Write-Log "Backup interrompido pelo usuário (Ctrl+C)." 'ERROR'
    } else {
        Write-Log "Falha no backup (exit code $code): $($_.Exception.Message)" 'ERROR'
    }
    Write-Log "Consulte o log em: $LogPath" 'ERROR'

    if ($DiscordSettings.Enabled -and $DiscordSettings.NotifyFailure) {
        $mention = $null
        if (-not $cancelled) {
            $mention = Get-DiscordMentionContentOnFailure -Discord $DiscordSettings
        }
        $tail = Get-LastLogLines -Path $LogPath -Tail $DiscordSettings.FailureIncludeLastLogLines
        $tail = ConvertTo-DiscordTextTruncated -Text $tail -MaxLength 900

        $dur = ''
        if ($script:BackupStartAt) {
            $span = (Get-Date) - $script:BackupStartAt
            $dur = ('{0:hh\:mm\:ss}' -f $span)
        }

        $fields = @(
            @{ name = 'Exit code'; value = "$code"; inline = $true },
            @{ name = 'Duração'; value = $dur; inline = $true },
            @{ name = 'Log backup'; value = $LogPath; inline = $false }
        )
        $rlp = Get-Variable -Name RcloneLogPaths -Scope Script -ErrorAction SilentlyContinue
        if ($rlp -and $rlp.Value -and $rlp.Value.ContainsKey($script:DiscordCurrentStep)) {
            $fields += @(@{ name = 'Log rclone'; value = [string]$rlp.Value[$script:DiscordCurrentStep]; inline = $false })
        }
        if (-not [string]::IsNullOrWhiteSpace($tail)) {
            $fields += @(@{ name = 'Últimas linhas do log'; value = $tail; inline = $false })
        }

        $title = if ($cancelled) { 'Backup Minecraft interrompido' } else { 'Backup Minecraft falhou' }
        $descText = if ($cancelled) { 'Execução interrompida pelo usuário (Ctrl+C) ou encerramento do terminal.' } else { $($_.Exception.Message) }
        $embed = New-DiscordEmbed -Title $title -Color 'red' -Description (ConvertTo-DiscordTextTruncated -Text $descText -MaxLength 1000) -Fields $fields
        $payload = @{ embeds = @($embed) }
        if (-not [string]::IsNullOrWhiteSpace($mention)) { $payload.content = $mention }
        if (-not [string]::IsNullOrWhiteSpace($DiscordSettings.Username)) { $payload.username = $DiscordSettings.Username }
        if (-not [string]::IsNullOrWhiteSpace($DiscordSettings.AvatarUrl)) { $payload.avatar_url = $DiscordSettings.AvatarUrl }
        $ctx = if ($cancelled) { 'cancelled' } else { 'failure' }
        Send-DiscordWebhook -Url $DiscordSettings.AlertUrl -Payload $payload -Discord $DiscordSettings -Context $ctx
    }
} finally {
    Stop-DiscordHeartbeatTimer -Timer $heartbeatTimer
    $LockPath = Join-Path $PastaTemp 'backup.lock'
    if ($script:CreatedLock -and (Test-Path $LockPath)) {
        Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
    }

    exit $script:ExitCode
}