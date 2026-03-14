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

function Get-LastLogLines {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][int]$Tail
    )
    if ($Tail -le 0) { return '' }
    if (!(Test-Path $Path)) { return '' }
    try {
        $lines = Get-Content -Path $Path -Tail $Tail -ErrorAction Stop
        return ($lines -join "`n")
    } catch {
        return ''
    }
}
