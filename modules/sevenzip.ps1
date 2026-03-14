function Invoke-7Zip {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$false)][string]$ProgressStage
    )

    if (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
        Set-DiscordStep -Step $ProgressStage
    }

    $finalArgs = @($Args)
    if (-not ($finalArgs -contains '-bso0')) { $finalArgs = @('-bso0') + $finalArgs }
    if (-not ($finalArgs -contains '-bsp0')) { $finalArgs = @('-bsp0') + $finalArgs }
    if (-not ($finalArgs -contains '-bse2')) { $finalArgs = @('-bse2') + $finalArgs }

    & $script:SevenZipExe @finalArgs

    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Stop-Backup -ExitCode $ExitCodes.Zip -Message "Falha ao executar o 7-Zip (exit code $code). Isso pode indicar arquivo em uso/permissão negada/sem espaço em disco. Verifique espaço em '$PastaTemp' e se o diretório não está travado por outro processo."
    }
}
