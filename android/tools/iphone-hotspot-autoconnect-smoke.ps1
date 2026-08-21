param(
    [ValidateRange(1, 20)]
    [int]$AttemptsPerOrder = 5,

    [ValidateRange(5, 60)]
    [int]$TimeoutSeconds = 45,

    [ValidateRange(0, 10)]
    [int]$StartGapSeconds = 1,

    [ValidateRange(0, 10)]
    [int]$RecoveryAttempts = 3,

    [ValidateRange(10, 90)]
    [int]$RecoveryTimeoutSeconds = 30,

    [string]$Serial = '',

    [string]$OutputDirectory = '',

    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$androidRoot = Join-Path $repoRoot 'android'
$desktopRoot = Join-Path $repoRoot 'desktop'
$packageName = 'com.nxtend.team35.yubiboard.debug'
$activityName = 'com.nxtend.team35.yubiboard.MainActivity'
$desktopExecutable = Join-Path $desktopRoot 'build\windows\x64\runner\Debug\thehack_overlay.exe'
$sdkCandidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    'C:\Android\Sdk'
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$sdkRoot = $sdkCandidates |
    Where-Object { Test-Path (Join-Path $_ 'platform-tools\adb.exe') } |
    Select-Object -First 1
if (-not $sdkRoot) {
    throw 'Android SDKを検出できません。ANDROID_HOMEまたはANDROID_SDK_ROOTを設定してください。'
}
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'

function Resolve-Device {
    $rows = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
    if ([string]::IsNullOrWhiteSpace($script:Serial)) {
        if ($rows.Count -eq 0) { throw 'ADB接続済み実機がありません。' }
        if ($rows.Count -gt 1) { throw '複数端末があります。-Serialを指定してください。' }
        $script:Serial = ($rows[0] -split '\s+')[0]
    } elseif (-not ($rows | Where-Object { $_ -match "^$([regex]::Escape($script:Serial))\s" })) {
        throw "端末 $($script:Serial) はdevice状態ではありません。"
    }
}

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $output = & $adb -s $script:Serial @Arguments
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $($Arguments -join ' ')" }
    return $output
}

function Build-SmokeTargets {
    Push-Location $androidRoot
    try {
        & '.\gradlew.bat' assembleDebug
        if ($LASTEXITCODE -ne 0) { throw 'Android debug APK build failed.' }
    } finally {
        Pop-Location
    }
    $apk = Join-Path $androidRoot 'app\build\outputs\apk\debug\app-debug.apk'
    & $adb -s $script:Serial install -r $apk
    if ($LASTEXITCODE -ne 0) { throw 'Android debug APK install failed.' }

    Push-Location $desktopRoot
    try {
        & flutter build windows --debug --dart-define=YUBI_AUTOFLOW=true
        if ($LASTEXITCODE -ne 0) { throw 'Desktop debug build failed.' }
    } finally {
        Pop-Location
    }
}

function Start-AndroidDiscovery {
    Invoke-Adb shell am force-stop $packageName | Out-Null
    Invoke-Adb -Arguments @(
        'shell', 'am', 'start', '-W',
        '-n', "$packageName/$activityName",
        '--ez', 'debugAutoDiscovery', 'true'
    ) | Out-Null
}

function Start-Desktop {
    return Start-Process -FilePath $desktopExecutable -PassThru -WindowStyle Hidden
}

function Stop-SmokeApps {
    param([System.Diagnostics.Process]$DesktopProcess)
    Invoke-Adb shell am force-stop $packageName | Out-Null
    if ($DesktopProcess -and -not $DesktopProcess.HasExited) {
        Stop-Process -Id $DesktopProcess.Id
        Wait-Process -Id $DesktopProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
}

function Get-DiagnosticEvents {
    $lines = Invoke-Adb -Arguments @('logcat', '-v', 'raw', '-d', '-s', 'YubiBoardDiag:I', '*:S')
    $events = @()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('{')) { continue }
        try {
            $event = $trimmed | ConvertFrom-Json
            if ($event.name) { $events += $event }
        } catch {
            # logcatの途中行は無視し、次のpollで完全な行を再取得する。
        }
    }
    return $events
}

function Get-EventTimestamp {
    param([object[]]$Events, [string]$Name)
    $event = $Events | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $event) { return $null }
    return [long]$event.timestampMs
}

function Get-Delta {
    param($From, $To)
    if ($null -eq $From -or $null -eq $To) { return $null }
    return [long]$To - [long]$From
}

function Wait-ForHelloAck {
    param([System.Diagnostics.Process]$DesktopProcess, [int]$Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $events = @(Get-DiagnosticEvents)
        if ($events | Where-Object { $_.name -eq 'hello_ack' } | Select-Object -First 1) {
            return $events
        }
        if ($DesktopProcess.HasExited) { return $events }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return @(Get-DiagnosticEvents)
}

function New-PhaseResult {
    param([int]$Attempt, [string]$Order, [object[]]$Events)
    $listen = Get-EventTimestamp $Events 'listen_started'
    $offer = Get-EventTimestamp $Events 'offer_received'
    $opened = Get-EventTimestamp $Events 'websocket_opened'
    $hello = Get-EventTimestamp $Events 'hello_sent'
    $ack = Get-EventTimestamp $Events 'hello_ack'
    $ackTimeouts = @($Events | Where-Object { $_.name -eq 'hello_ack_timeout' }).Count
    $failures = @($Events | Where-Object { $_.name -eq 'websocket_failure' }).Count
    $success = $null -ne $ack
    $failurePhase = if ($success) {
        ''
    } elseif ($null -eq $offer) {
        'udp_offer'
    } elseif ($null -eq $opened) {
        'websocket_open'
    } elseif ($null -eq $hello) {
        'hello_send'
    } else {
        'hello_ack'
    }
    return [pscustomobject][ordered]@{
        attempt = $Attempt
        order = $Order
        success = $success
        listenToOfferMs = Get-Delta $listen $offer
        offerToOpenMs = Get-Delta $offer $opened
        openToHelloMs = Get-Delta $opened $hello
        helloToAckMs = Get-Delta $hello $ack
        offerToAckMs = Get-Delta $offer $ack
        totalMs = Get-Delta $listen $ack
        ackTimeouts = $ackTimeouts
        websocketFailures = $failures
        failurePhase = $failurePhase
    }
}

function Invoke-ConnectionAttempt {
    param([int]$Attempt, [ValidateSet('android-first', 'desktop-first')][string]$Order)
    $desktopProcess = $null
    try {
        Invoke-Adb logcat -c | Out-Null
        if ($Order -eq 'android-first') {
            Start-AndroidDiscovery
            Start-Sleep -Seconds $StartGapSeconds
            $desktopProcess = Start-Desktop
        } else {
            $desktopProcess = Start-Desktop
            Start-Sleep -Seconds $StartGapSeconds
            Start-AndroidDiscovery
        }
        $events = @(Wait-ForHelloAck $desktopProcess $TimeoutSeconds)
        return New-PhaseResult $Attempt $Order $events
    } finally {
        Stop-SmokeApps $desktopProcess
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-RecoveryCheck {
    $desktopProcess = $null
    $results = @()
    try {
        Invoke-Adb logcat -c | Out-Null
        Start-AndroidDiscovery
        $desktopProcess = Start-Desktop
        $initial = @(Wait-ForHelloAck $desktopProcess $TimeoutSeconds)
        if (-not ($initial | Where-Object { $_.name -eq 'hello_ack' })) {
            return @([pscustomobject]@{ attempt = 0; success = $false; reconnectMs = $null })
        }
        for ($attempt = 1; $attempt -le $RecoveryAttempts; $attempt++) {
            Invoke-Adb logcat -c | Out-Null
            Invoke-Adb shell svc wifi disable | Out-Null
            Start-Sleep -Seconds 2
            Invoke-Adb shell svc wifi enable | Out-Null
            $events = @(Wait-ForHelloAck $desktopProcess $RecoveryTimeoutSeconds)
            $available = Get-EventTimestamp $events 'default_network_available'
            $opened = Get-EventTimestamp $events 'websocket_opened'
            $hello = Get-EventTimestamp $events 'hello_sent'
            $ack = Get-EventTimestamp $events 'hello_ack'
            $ackTimeouts = @($events | Where-Object { $_.name -eq 'hello_ack_timeout' }).Count
            $failures = @($events | Where-Object { $_.name -eq 'websocket_failure' }).Count
            $results += [pscustomobject][ordered]@{
                attempt = $attempt
                success = $null -ne $ack
                reconnectMs = Get-Delta $available $ack
                websocketOpened = $null -ne $opened
                helloSent = $null -ne $hello
                ackTimeouts = $ackTimeouts
                websocketFailures = $failures
            }
        }
        return $results
    } finally {
        Invoke-Adb shell svc wifi enable | Out-Null
        Stop-SmokeApps $desktopProcess
    }
}

Resolve-Device
if (Get-Process -Name 'thehack_overlay' -ErrorAction SilentlyContinue) {
    throw 'thehack_overlayが既に起動しています。既存アプリを終了してから再実行してください。'
}
if ($Build) { Build-SmokeTargets }
if (-not (Test-Path $desktopExecutable)) {
    throw "Desktop debug実行ファイルがありません。-Buildを付けて実行してください: $desktopExecutable"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $androidRoot "debug-results\autoconnect-$stamp"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$results = @()
foreach ($order in @('android-first', 'desktop-first')) {
    for ($attempt = 1; $attempt -le $AttemptsPerOrder; $attempt++) {
        Write-Host "[$order] attempt $attempt/$AttemptsPerOrder"
        $result = Invoke-ConnectionAttempt $attempt $order
        $results += $result
        Write-Host "  success=$($result.success) offerToAckMs=$($result.offerToAckMs) totalMs=$($result.totalMs) ackTimeouts=$($result.ackTimeouts) phase=$($result.failurePhase)"
    }
}
$results | Export-Csv (Join-Path $OutputDirectory 'connection-attempts.csv') -NoTypeInformation -Encoding utf8

$recoveryResults = @()
if ($RecoveryAttempts -gt 0) {
    Write-Host "[recovery] attempts=$RecoveryAttempts"
    $recoveryResults = @(Invoke-RecoveryCheck)
    $recoveryResults | Export-Csv (Join-Path $OutputDirectory 'recovery-attempts.csv') -NoTypeInformation -Encoding utf8
}

$failed = @($results | Where-Object { -not $_.success }).Count
$ackTimeouts = ($results | Measure-Object -Property ackTimeouts -Sum).Sum
# Android先行時のDesktop debug cold startは接続処理ではない。両者の準備が
# 揃った最初の証拠であるoffer受信からhello_ackまでを10秒基準にする。
$slow = @($results | Where-Object { $null -ne $_.offerToAckMs -and $_.offerToAckMs -gt 10000 }).Count
$recoveryFailed = @($recoveryResults | Where-Object { -not $_.success }).Count
$summary = [pscustomobject][ordered]@{
    generatedAt = (Get-Date).ToString('o')
    deviceModel = (Invoke-Adb shell getprop ro.product.model | Out-String).Trim()
    attempts = $results.Count
    succeeded = $results.Count - $failed
    failed = $failed
    overTenSeconds = $slow
    ackTimeouts = $ackTimeouts
    recoveryAttempts = $recoveryResults.Count
    recoveryFailed = $recoveryFailed
}
$summary | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'summary.json') -Encoding utf8
$summary | Format-List | Out-Host
Write-Host "Results: $OutputDirectory"

if ($failed -gt 0 -or $slow -gt 0 -or $ackTimeouts -gt 0 -or $recoveryFailed -gt 0) {
    throw '自動接続スモークの合格条件を満たしませんでした。CSVで失敗段階を確認してください。'
}
