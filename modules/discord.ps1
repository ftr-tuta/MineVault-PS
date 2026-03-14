function ConvertTo-DiscordColor {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('blue','gray','green','red')][string]$Name
    )
    switch ($Name) {
        'blue'  { return 3447003 }
        'gray'  { return 9807270 }
        'green' { return 3066993 }
        'red'   { return 15158332 }
    }
}

function ConvertTo-DiscordTextTruncated {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory=$true)][int]$MaxLength
    )
    if ($MaxLength -le 0) { return '' }
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    return ($Text.Substring(0, [Math]::Max(0, $MaxLength - 3)) + '...')
}

function Get-DiscordSettings {
    param([Parameter(Mandatory=$true)][object]$Cfg)

    $d = $null
    if ($Cfg.discord) { $d = $Cfg.discord }

    $enabled = $false
    if ($d -and ($null -ne $d.enabled)) { $enabled = [bool]$d.enabled }

    $normalUrl = $null
    $alertUrl = $null
    if ($d -and $d.webhooks) {
        if ($d.webhooks.normalUrl) { $normalUrl = [string]$d.webhooks.normalUrl }
        if ($d.webhooks.alertUrl) { $alertUrl = [string]$d.webhooks.alertUrl }
    }

    $username = $null
    $avatarUrl = $null
    if ($d -and $d.identity) {
        if ($d.identity.username) { $username = [string]$d.identity.username }
        if ($d.identity.avatarUrl) { $avatarUrl = [string]$d.identity.avatarUrl }
    }

    $notifyStart = $true
    $notifySuccess = $true
    $notifyFailure = $true
    if ($d -and $d.notifications) {
        if ($d.notifications.start -and ($null -ne $d.notifications.start.enabled)) { $notifyStart = [bool]$d.notifications.start.enabled }
        if ($d.notifications.success -and ($null -ne $d.notifications.success.enabled)) { $notifySuccess = [bool]$d.notifications.success.enabled }
        if ($d.notifications.failure -and ($null -ne $d.notifications.failure.enabled)) { $notifyFailure = [bool]$d.notifications.failure.enabled }
    }

    $mentionHere = $false
    $mentionRoleId = $null
    if ($d -and $d.mentions -and $d.mentions.onFailure) {
        if ($null -ne $d.mentions.onFailure.here) { $mentionHere = [bool]$d.mentions.onFailure.here }
        if ($d.mentions.onFailure.roleId) { $mentionRoleId = [string]$d.mentions.onFailure.roleId }
    }

    $heartbeatEnabled = $false
    $heartbeatIntervalSeconds = 300
    if ($d -and $d.heartbeat) {
        if ($null -ne $d.heartbeat.enabled) { $heartbeatEnabled = [bool]$d.heartbeat.enabled }
        if ($null -ne $d.heartbeat.intervalSeconds) { $heartbeatIntervalSeconds = [int]$d.heartbeat.intervalSeconds }
    }
    if ($heartbeatIntervalSeconds -lt 1) { $heartbeatIntervalSeconds = 1 }

    $includeLastLogLines = 25
    if ($d -and $d.failure -and ($null -ne $d.failure.includeLastLogLines)) { $includeLastLogLines = [int]$d.failure.includeLastLogLines }
    if ($includeLastLogLines -lt 0) { $includeLastLogLines = 0 }

    $failBackupOnDiscordError = $false
    if ($d -and $d.behavior -and ($null -ne $d.behavior.failBackupOnDiscordError)) { $failBackupOnDiscordError = [bool]$d.behavior.failBackupOnDiscordError }

    [pscustomobject]@{
        Enabled = $enabled
        NormalUrl = $normalUrl
        AlertUrl = $alertUrl
        Username = $username
        AvatarUrl = $avatarUrl
        NotifyStart = $notifyStart
        NotifySuccess = $notifySuccess
        NotifyFailure = $notifyFailure
        MentionHereOnFailure = $mentionHere
        MentionRoleIdOnFailure = $mentionRoleId
        HeartbeatEnabled = $heartbeatEnabled
        HeartbeatIntervalSeconds = $heartbeatIntervalSeconds
        FailureIncludeLastLogLines = $includeLastLogLines
        FailBackupOnDiscordError = $failBackupOnDiscordError
    }
}

function New-DiscordEmbed {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][ValidateSet('blue','gray','green','red')][string]$Color,
        [Parameter(Mandatory=$false)][string]$Description,
        [Parameter(Mandatory=$false)][hashtable[]]$Fields
    )
    $e = @{
        title = (ConvertTo-DiscordTextTruncated -Text $Title -MaxLength 256)
        color = (ConvertTo-DiscordColor -Name $Color)
        timestamp = (Get-Date).ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        $e.description = (ConvertTo-DiscordTextTruncated -Text $Description -MaxLength 2048)
    }
    if ($Fields -and $Fields.Count -gt 0) {
        $e.fields = @()
        foreach ($f in $Fields) {
            if ($null -eq $f) { continue }
            $name = if ($f.ContainsKey('name')) { [string]$f.name } else { '' }
            $value = if ($f.ContainsKey('value')) { [string]$f.value } else { '' }
            $inline = $false
            if ($f.ContainsKey('inline')) { $inline = [bool]$f.inline }
            $e.fields += @{
                name = (ConvertTo-DiscordTextTruncated -Text $name -MaxLength 256)
                value = (ConvertTo-DiscordTextTruncated -Text $value -MaxLength 1024)
                inline = $inline
            }
        }
    }
    return $e
}

function Send-DiscordWebhook {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][hashtable]$Payload,
        [Parameter(Mandatory=$true)][object]$Discord,
        [Parameter(Mandatory=$true)][string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return }

    $json = ($Payload | ConvertTo-Json -Depth 12)
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-RestMethod -Method Post -Uri $Url -Body $json -ContentType 'application/json' -TimeoutSec 15 | Out-Null
            return
        } catch {
            $statusCode = $null
            $retryAfterSeconds = $null

            $resp = $null
            if ($_.Exception -and $_.Exception.Response) {
                $resp = $_.Exception.Response
                try {
                    $statusCode = [int]$resp.StatusCode
                } catch { }
                try {
                    $ra = $resp.Headers['Retry-After']
                    if ($ra) {
                        $retryAfterSeconds = [int]$ra
                    }
                } catch { }
            }

            if ($attempt -lt $maxAttempts -and $statusCode -eq 429) {
                if ($null -eq $retryAfterSeconds -or $retryAfterSeconds -le 0) { $retryAfterSeconds = 5 }
                Start-Sleep -Seconds $retryAfterSeconds
                continue
            }

            $suffix = ""
            if ($null -ne $statusCode) { $suffix = " (HTTP $statusCode)" }
            $msg = "Discord webhook falhou ({0}){1}: {2}" -f $Context, $suffix, $($_.Exception.Message)
            if ($Discord.FailBackupOnDiscordError) {
                throw $msg
            } else {
                $wl = Get-Command -Name Write-Log -ErrorAction SilentlyContinue
                if ($wl) {
                    Write-Log $msg 'WARN'
                } else {
                    Write-Host $msg -ForegroundColor Yellow
                }
                return
            }
        }
    }
}

function Get-DiscordMentionContentOnFailure {
    param([Parameter(Mandatory=$true)][object]$Discord)

    if ($Discord.MentionHereOnFailure) { return '@here' }
    if (-not [string]::IsNullOrWhiteSpace($Discord.MentionRoleIdOnFailure)) {
        return "<@&$($Discord.MentionRoleIdOnFailure)>"
    }
    return $null
}

function Initialize-DiscordState {
    param([Parameter(Mandatory=$true)][object]$Discord)
    $script:Discord = $Discord
    $script:DiscordState = @{
        heartbeatJob = $null
    }
}

function Set-DiscordStep {
    param([Parameter(Mandatory=$true)][string]$Step)
    $script:DiscordCurrentStep = $Step
    try {
        Update-DiscordHeartbeatState -Step $Step
    } catch { }
}

function Update-DiscordHeartbeatState {
    param(
        [Parameter(Mandatory=$false)][string]$Step,
        [Parameter(Mandatory=$false)][string]$BackupLogPath,
        [Parameter(Mandatory=$false)][string]$RcloneLogPath
    )

    $p = $null
    $pVar = Get-Variable -Name HeartbeatStatePath -Scope Global -ErrorAction SilentlyContinue
    if ($pVar) { $p = [string]$pVar.Value }
    if ([string]::IsNullOrWhiteSpace($p)) { return }

    $state = @{}
    if (Test-Path $p) {
        try {
            $raw = Get-Content -Path $p -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                $state = @{}
                foreach ($prop in $obj.PSObject.Properties) {
                    $state[$prop.Name] = $prop.Value
                }
            }
        } catch {
            $state = @{}
        }
    }

    if (-not $state.ContainsKey('startAt')) {
        $state['startAt'] = (Get-Date).ToString('o')
    }

    if ($BackupLogPath) {
        $state['backupLogPath'] = $BackupLogPath
    }

    if ($Step) {
        $prevStep = $null
        if ($state.ContainsKey('step')) { $prevStep = [string]$state['step'] }
        $state['step'] = $Step
        if ($null -eq $prevStep -or $prevStep -ne $Step) {
            $state['stepStartedAt'] = (Get-Date).ToString('o')
        }
    } elseif (-not $state.ContainsKey('step')) {
        $state['step'] = $script:DiscordCurrentStep
    }

    if ($RcloneLogPath -and $Step) {
        if (-not $state.ContainsKey('rcloneLogs') -or $null -eq $state['rcloneLogs']) {
            $state['rcloneLogs'] = @{}
        }
        if (-not ($state['rcloneLogs'] -is [hashtable])) {
            $tmp = @{}
            try {
                foreach ($prop in $state['rcloneLogs'].PSObject.Properties) {
                    $tmp[$prop.Name] = $prop.Value
                }
            } catch { }
            $state['rcloneLogs'] = $tmp
        }
        try {
            $state['rcloneLogs'][$Step] = $RcloneLogPath
        } catch { }
    }

    $state['updatedAt'] = (Get-Date).ToString('o')
    $json = $state | ConvertTo-Json -Depth 10
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force -ErrorAction SilentlyContinue
    Set-Content -Path $p -Value $json -Encoding UTF8
}

function Send-DiscordHeartbeat {
    param(
        [Parameter(Mandatory=$true)][object]$Discord,
        [Parameter(Mandatory=$true)][string]$BackupLogPath,
        [Parameter(Mandatory=$false)][string]$RcloneLogPath
    )

    if (-not $Discord.Enabled) { return }
    if (-not $Discord.HeartbeatEnabled) { return }
    if ([string]::IsNullOrWhiteSpace($Discord.NormalUrl)) { return }

    $elapsed = ''
    if ($script:BackupStartAt) {
        $span = (Get-Date) - $script:BackupStartAt
        $elapsed = ('{0:hh\:mm\:ss}' -f $span)
    }

    $step = $script:DiscordCurrentStep
    if ([string]::IsNullOrWhiteSpace($step)) { $step = 'init' }

    $fields = @(
        @{ name = 'Etapa atual'; value = $step; inline = $true },
        @{ name = 'Rodando há'; value = $elapsed; inline = $true },
        @{ name = 'Log backup'; value = $BackupLogPath; inline = $false }
    )
    if (-not [string]::IsNullOrWhiteSpace($RcloneLogPath)) {
        $fields += @(@{ name = 'Log rclone'; value = $RcloneLogPath; inline = $false })
    }

    $embed = New-DiscordEmbed -Title 'Backup Minecraft - Heartbeat' -Color 'gray' -Description $null -Fields $fields
    $payload = @{ embeds = @($embed) }
    if (-not [string]::IsNullOrWhiteSpace($Discord.Username)) { $payload.username = $Discord.Username }
    if (-not [string]::IsNullOrWhiteSpace($Discord.AvatarUrl)) { $payload.avatar_url = $Discord.AvatarUrl }

    Send-DiscordWebhook -Url $Discord.NormalUrl -Payload $payload -Discord $Discord -Context 'heartbeat'
}

function Start-DiscordHeartbeatTimer {
    param(
        [Parameter(Mandatory=$true)][object]$Discord,
        [Parameter(Mandatory=$true)][string]$BackupLogPath
    )

    return (Start-DiscordHeartbeatJob -Discord $Discord -BackupLogPath $BackupLogPath)
}

function Stop-DiscordHeartbeatTimer {
    param([Parameter(Mandatory=$false)][object]$Timer)

    Stop-DiscordHeartbeatJob -Job $Timer
}

function Start-DiscordHeartbeatJob {
    param(
        [Parameter(Mandatory=$true)][object]$Discord,
        [Parameter(Mandatory=$true)][string]$BackupLogPath
    )

    if (-not $Discord.Enabled) { return $null }
    if (-not $Discord.HeartbeatEnabled) { return $null }
    if ($Discord.HeartbeatIntervalSeconds -le 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($Discord.NormalUrl)) {
        $wl = Get-Command -Name Write-Log -ErrorAction SilentlyContinue
        if ($wl) { Write-Log 'Heartbeat do Discord está habilitado, mas discord.webhooks.normalUrl está vazio. Heartbeat não será enviado.' 'WARN' }
        return $null
    }

    $p = $null
    $pVar = Get-Variable -Name HeartbeatStatePath -Scope Global -ErrorAction SilentlyContinue
    if ($pVar) { $p = [string]$pVar.Value }
    if ([string]::IsNullOrWhiteSpace($p)) {
        $wl = Get-Command -Name Write-Log -ErrorAction SilentlyContinue
        if ($wl) { Write-Log 'Heartbeat do Discord não pôde iniciar: HeartbeatStatePath não foi definido.' 'WARN' }
        return $null
    }

    Update-DiscordHeartbeatState -BackupLogPath $BackupLogPath -Step $script:DiscordCurrentStep

    $interval = [Math]::Max(1, [int]$Discord.HeartbeatIntervalSeconds)
    $url = [string]$Discord.NormalUrl
    $username = [string]$Discord.Username
    $avatarUrl = [string]$Discord.AvatarUrl

    $existing = $null
    if ($script:DiscordState -and $script:DiscordState.heartbeatJob) { $existing = $script:DiscordState.heartbeatJob }
    if ($existing) {
        Stop-DiscordHeartbeatJob -Job $existing
    }

    $job = Start-Job -Name 'discordHeartbeat' -ArgumentList @($p, $interval, $url, $username, $avatarUrl, $BackupLogPath) -ScriptBlock {
        param($statePath, $intervalSeconds, $url, $username, $avatarUrl, $defaultBackupLogPath)

        $ErrorActionPreference = 'Stop'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch { }

        $nextRegularSendAt = Get-Date
        $lastStepSeen = ''
        $forcedSyncSent = $false

        while ($true) {
            try {
                $state = $null
                if (-not [string]::IsNullOrWhiteSpace($statePath) -and (Test-Path $statePath)) {
                    $raw = Get-Content -Path $statePath -Raw -ErrorAction Stop
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $state = $raw | ConvertFrom-Json -ErrorAction Stop
                    }
                }

                $step = 'init'
                $backupLogPath = $defaultBackupLogPath
                $rcloneLogPath = ''
                $startAt = $null
                $stepStartedAt = $null

                if ($state) {
                    if ($state.step) { $step = [string]$state.step }
                    if ($state.backupLogPath) { $backupLogPath = [string]$state.backupLogPath }
                    if ($state.startAt) {
                        try { $startAt = [datetime]::Parse([string]$state.startAt) } catch { }
                    }
                    if ($state.stepStartedAt) {
                        try { $stepStartedAt = [datetime]::Parse([string]$state.stepStartedAt) } catch { }
                    }
                    if ($state.rcloneLogs) {
                        try {
                            if ($state.rcloneLogs -is [hashtable]) {
                                if ($state.rcloneLogs.ContainsKey($step)) { $rcloneLogPath = [string]$state.rcloneLogs[$step] }
                            } else {
                                $v = $state.rcloneLogs.$step
                                if ($v) { $rcloneLogPath = [string]$v }
                            }
                        } catch { }
                    }
                }

                if ($step -ne $lastStepSeen) {
                    $lastStepSeen = $step
                    $forcedSyncSent = $false
                }

                $now = Get-Date
                $shouldSend = $false
                if ($now -ge $nextRegularSendAt) {
                    $shouldSend = $true
                }

                if (-not $forcedSyncSent -and $step -eq 'sync' -and $stepStartedAt) {
                    $stepElapsed = ($now - $stepStartedAt).TotalSeconds
                    if ($stepElapsed -ge 45) {
                        $shouldSend = $true
                        $forcedSyncSent = $true
                    }
                }

                if (-not $shouldSend) {
                    Start-Sleep -Seconds 1
                    continue
                }

                $transferredLine = $null
                if ($step -eq 'sync' -and -not [string]::IsNullOrWhiteSpace($rcloneLogPath) -and (Test-Path $rcloneLogPath)) {
                    try {
                        $lines = Get-Content -Path $rcloneLogPath -Tail 300 -ErrorAction Stop

                        $best = $null
                        $bestScore = -1
                        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                            $line = [string]$lines[$i]
                            if ($line -notmatch 'Transferred:\s+') { continue }
                            $trim = $line.Trim()

                            if ($trim -notmatch '\bETA\b') { continue }

                            $score = 0
                            $score += 4
                            if ($trim -match '/\s*\d') { $score += 2 }
                            if ($trim -match '(MiB|GiB|KiB|bytes|B)\b') { $score += 2 }
                            if ($trim -match '/s\b') { $score += 2 }
                            if ($trim -match '\b\d+%\b') { $score += 1 }
                            if ($trim.Length -ge 40) { $score += 1 }

                            if ($score -gt $bestScore) {
                                $bestScore = $score
                                $best = $trim
                            }

                            if ($bestScore -ge 9) { break }
                        }
                        if ($best) {
                            $transferredLine = $best
                        }

                        if (-not $transferredLine) {
                            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                                $line = [string]$lines[$i]
                                if ($line -match '\bETA\b') {
                                    $transferredLine = $line.Trim()
                                    break
                                }
                            }
                        }

                        if (-not $transferredLine) { $transferredLine = 'Transferred ainda não foi registrado no log' }
                    } catch {
                        $transferredLine = 'Transferred ainda não foi registrado no log'
                    }
                }

                $elapsed = ''
                if ($startAt) {
                    $span = (Get-Date) - $startAt
                    $elapsed = ('{0:hh\:mm\:ss}' -f $span)
                }

                $fields = @(
                    @{ name = 'Etapa atual'; value = $step; inline = $true },
                    @{ name = 'Rodando há'; value = $elapsed; inline = $true }
                )
                if (-not [string]::IsNullOrWhiteSpace($backupLogPath)) {
                    $fields += @(@{ name = 'Log backup'; value = $backupLogPath; inline = $false })
                }
                if (-not [string]::IsNullOrWhiteSpace($rcloneLogPath)) {
                    $fields += @(@{ name = 'Log rclone'; value = $rcloneLogPath; inline = $false })
                }
                if (-not [string]::IsNullOrWhiteSpace($transferredLine)) {
                    $fields += @(@{ name = 'Sync'; value = $transferredLine; inline = $false })
                }

                $embed = @{ title = 'Backup Minecraft - Heartbeat'; color = 9807270; timestamp = (Get-Date).ToString('o'); fields = $fields }
                $payload = @{ embeds = @($embed) }
                if (-not [string]::IsNullOrWhiteSpace($username)) { $payload.username = $username }
                if (-not [string]::IsNullOrWhiteSpace($avatarUrl)) { $payload.avatar_url = $avatarUrl }
                $json = $payload | ConvertTo-Json -Depth 10
                Invoke-RestMethod -Method Post -Uri $url -Body $json -ContentType 'application/json' -TimeoutSec 15 | Out-Null
                $nextRegularSendAt = (Get-Date).AddSeconds($intervalSeconds)
            } catch {
                try {
                    $bp = $backupLogPath
                    if ([string]::IsNullOrWhiteSpace($bp)) { $bp = $defaultBackupLogPath }
                    if (-not [string]::IsNullOrWhiteSpace($bp)) {
                        $line = "[{0}] [WARN] Falha ao enviar heartbeat do Discord (job): {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $($_.Exception.Message)
                        Add-Content -Path $bp -Value $line
                    }
                } catch { }
            }
            Start-Sleep -Seconds 1
        }
    }

    $script:DiscordState.heartbeatJob = $job
    $wl = Get-Command -Name Write-Log -ErrorAction SilentlyContinue
    if ($wl) { Write-Log ("Heartbeat do Discord iniciado (intervalo: {0}s)." -f $interval) 'INFO' }
    return $job
}

function Stop-DiscordHeartbeatJob {
    param([Parameter(Mandatory=$false)][object]$Job)

    $j = $Job
    if (-not $j -and $script:DiscordState -and $script:DiscordState.heartbeatJob) {
        $j = $script:DiscordState.heartbeatJob
    }
    if ($j) {
        try { Stop-Job -Job $j -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($script:DiscordState) { $script:DiscordState.heartbeatJob = $null }
}

function Send-DiscordStageEvent {
    param(
        [Parameter(Mandatory=$true)][object]$Discord,
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][ValidateSet('blue','gray','green','red')][string]$Color,
        [Parameter(Mandatory=$false)][string]$Description,
        [Parameter(Mandatory=$false)][hashtable[]]$Fields,
        [Parameter(Mandatory=$false)][switch]$Alert
    )

    if (-not $Discord.Enabled) { return }

    $url = if ($Alert) { $Discord.AlertUrl } else { $Discord.NormalUrl }
    if ([string]::IsNullOrWhiteSpace($url)) { return }

    $embed = New-DiscordEmbed -Title $Title -Color $Color -Description $Description -Fields $Fields
    $payload = @{ embeds = @($embed) }
    if (-not [string]::IsNullOrWhiteSpace($Discord.Username)) { $payload.username = $Discord.Username }
    if (-not [string]::IsNullOrWhiteSpace($Discord.AvatarUrl)) { $payload.avatar_url = $Discord.AvatarUrl }

    Send-DiscordWebhook -Url $url -Payload $payload -Discord $Discord -Context $Kind
}
