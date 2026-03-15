function Get-Config {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!(Test-Path $Path)) {
        throw "Arquivo de configuracao nao encontrado: '$Path'. Crie um config.json (use o config.json.example como base)."
    }
    $raw = Get-Content -Path $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Arquivo de configuracao esta vazio: '$Path'."
    }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        throw "Falha ao parsear JSON em '$Path': $($_.Exception.Message)"
    }
}
