function Invoke-Rclone {
    param(
        [Parameter(Mandatory=$true)][string[]]$RcloneArgs,
        [int]$MaxAttempts = 3,
        [Parameter(Mandatory=$false)][string]$ProgressStage,
        [Parameter(Mandatory=$false)][string]$LogPath
    )
    $pretty = "rclone {0}" -f ($RcloneArgs -join ' ')
    Invoke-WithRetry -ActionName $pretty -MaxAttempts $MaxAttempts -Action {
        $rcloneLogVar = Get-Variable -Name RcloneLogPaths -Scope Script -ErrorAction SilentlyContinue
        if (-not $rcloneLogVar) {
            Set-Variable -Name RcloneLogPaths -Scope Script -Value @{} -Force
        }

        if (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
            Set-DiscordStep -Step $ProgressStage
        }

        $rcloneLog = $null
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $rcloneLog = $LogPath
        } elseif (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
            $rcloneLog = Join-Path $LogDir ("rclone_{0}_{1}.log" -f $ProgressStage, $Data)
        }

        if (-not [string]::IsNullOrWhiteSpace($rcloneLog)) {
            if (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
                $script:RcloneLogPaths[$ProgressStage] = $rcloneLog
            }
        }

        $finalArgs = @($RcloneArgs)
        if (-not [string]::IsNullOrWhiteSpace($rcloneLog)) {
            $globalFlags = @(
                '--log-level', 'NOTICE',
                '--log-file', $rcloneLog
            )
            if ($ProgressStage -eq 'sync') {
                $globalFlags = @(
                    '--stats', '30s',
                    '--stats-log-level', 'NOTICE'
                ) + $globalFlags
            }
            $finalArgs = @($globalFlags + $finalArgs)
        }

        if (-not [string]::IsNullOrWhiteSpace($rcloneLog)) {
            & rclone @finalArgs 1>$null 2>$null
        } else {
            & rclone @finalArgs
        }

        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Stop-Backup -ExitCode $ExitCodes.Rclone -Message "Falha ao executar: $pretty (exit code $code). Causas comuns: remote não existe no 'rclone config', credenciais inválidas, permissão negada, rede instável, ou caminho remoto incorreto."
        }
    }
}
