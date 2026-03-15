function Invoke-7Zip {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$false)][string]$ProgressStage,
        [Parameter(Mandatory=$false)][string]$LogPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
        Set-DiscordStep -Step $ProgressStage
    }

    $finalArgs = @($Args)

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        if (-not ($finalArgs -contains '-bso0')) { $finalArgs = @('-bso0') + $finalArgs }
        if (-not ($finalArgs -contains '-bsp0')) { $finalArgs = @('-bsp0') + $finalArgs }
        if (-not ($finalArgs -contains '-bse2')) { $finalArgs = @('-bse2') + $finalArgs }

        & $script:SevenZipExe @finalArgs
        $code = $LASTEXITCODE
    } else {
        if (-not ($finalArgs -contains '-bso1')) { $finalArgs = @('-bso1') + $finalArgs }
        if (-not ($finalArgs -contains '-bsp1')) { $finalArgs = @('-bsp1') + $finalArgs }
        if (-not ($finalArgs -contains '-bse2')) { $finalArgs = @('-bse2') + $finalArgs }

        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force -ErrorAction SilentlyContinue
        if (Test-Path $LogPath) { Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue }

        function ConvertTo-7zArgQuoted {
            param([Parameter(Mandatory=$true)][string]$A)
            if ($A -match '[\s\"]') {
                return '"' + ($A -replace '"', '\\"') + '"'
            }
            return $A
        }

        $argLine = ($finalArgs | ForEach-Object { ConvertTo-7zArgQuoted -A ([string]$_) }) -join ' '
        $errPath = ($LogPath + '.err')
        if (Test-Path $errPath) { Remove-Item -Path $errPath -Force -ErrorAction SilentlyContinue }

        $p = Start-Process -FilePath $script:SevenZipExe -ArgumentList $argLine -NoNewWindow -Wait -PassThru -RedirectStandardOutput $LogPath -RedirectStandardError $errPath
        $code = 0
        try { $code = [int]$p.ExitCode } catch { $code = 1 }

        try {
            if (Test-Path $errPath) {
                $e = Get-Content -Path $errPath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($e)) {
                    Add-Content -Path $LogPath -Value $e -Encoding utf8
                }
            }
        } catch { }
        try { Remove-Item -Path $errPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($code -ne 0) {
        Stop-Backup -ExitCode $ExitCodes.Zip -Message "Falha ao executar o 7-Zip (exit code $code). Isso pode indicar arquivo em uso/permissao negada/sem espaco em disco. Verifique espaco em '$PastaTemp' e se o diretorio nao esta travado por outro processo."
    }
}
