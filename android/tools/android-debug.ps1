param(
    [ValidateSet('doctor', 'build', 'install', 'usb', 'lan', 'test', 'start', 'soak', 'all')]
    [string]$Action = 'doctor',

    [string]$Serial = '',

    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidateRange(1, 120)]
    [int]$DurationMinutes = 10,

    [string]$OutputDirectory = '',

    [switch]$GrantCamera,

    [switch]$ResetAppData
)

$ErrorActionPreference = 'Stop'
$packageName = 'com.nxtend.team35.yubiboard'
$androidRoot = Split-Path $PSScriptRoot -Parent
$sdkCandidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    'C:\Android\Sdk'
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$sdkRoot = $sdkCandidates | Where-Object { Test-Path (Join-Path $_ 'platform-tools\adb.exe') } | Select-Object -First 1
if (-not $sdkRoot) { throw 'Android SDKを検出できません。ANDROID_HOMEまたはANDROID_SDK_ROOTを設定してください。' }
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
$gradle = Join-Path $androidRoot 'gradlew.bat'

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $prefix = if ([string]::IsNullOrWhiteSpace($Serial)) { @() } else { @('-s', $Serial) }
    & $adb @prefix @Arguments
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $($Arguments -join ' ')" }
}

function Install-Apk {
    param([string]$Path)
    $prefix = if ([string]::IsNullOrWhiteSpace($Serial)) { @() } else { @('-s', $Serial) }
    $result = & $adb @prefix install -r $Path 2>&1
    $result | Out-Host
    if ($LASTEXITCODE -ne 0) {
        $message = $result | Out-String
        if ($message -match 'INSTALL_FAILED_USER_RESTRICTED') {
            throw '端末がADBインストールを拒否しました。端末をロック解除し、開発者向けオプションの「USB経由のインストール」を有効化して、表示される確認を許可してください。'
        }
        throw "APK install failed: $Path"
    }
}

function Resolve-Device {
    $rows = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
    if ([string]::IsNullOrWhiteSpace($Serial)) {
        if ($rows.Count -eq 0) { throw 'ADB接続済み実機がありません。USBデバッグを確認してください。' }
        if ($rows.Count -gt 1) { throw '複数端末があります。-Serialを指定してください。' }
        $script:Serial = ($rows[0] -split '\s+')[0]
    } elseif (-not ($rows | Where-Object { $_ -match "^$([regex]::Escape($Serial))\s" })) {
        throw "端末 $Serial はdevice状態ではありません。"
    }
}

function New-ResultDirectory {
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:OutputDirectory = Join-Path $androidRoot "debug-results\device-$stamp"
    }
    $script:OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}

function Invoke-Doctor {
    Resolve-Device
    $facts = [ordered]@{
        adb = $adb
        sdkRoot = $sdkRoot
        serial = $Serial
        manufacturer = (Invoke-Adb shell getprop ro.product.manufacturer | Out-String).Trim()
        model = (Invoke-Adb shell getprop ro.product.model | Out-String).Trim()
        android = (Invoke-Adb shell getprop ro.build.version.release | Out-String).Trim()
        sdk = (Invoke-Adb shell getprop ro.build.version.sdk | Out-String).Trim()
        resolution = (Invoke-Adb shell wm size | Out-String).Trim()
        packageInstalled = [bool]((Invoke-Adb shell pm list packages $packageName | Out-String).Trim())
    }
    $facts.GetEnumerator() | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value }
}

function Invoke-Build {
    Push-Location $androidRoot
    try {
        & $gradle testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest
        if ($LASTEXITCODE -ne 0) { throw 'Gradle verification failed.' }
    } finally {
        Pop-Location
    }
}

function Build-DebugApks {
    param([switch]$IncludeTest)
    Push-Location $androidRoot
    try {
        $tasks = @('assembleDebug')
        if ($IncludeTest) { $tasks += 'assembleDebugAndroidTest' }
        & $gradle @tasks
        if ($LASTEXITCODE -ne 0) { throw 'Debug APK build failed.' }
    } finally {
        Pop-Location
    }
}

function Install-App {
    Resolve-Device
    if ($ResetAppData) {
        $installed = (Invoke-Adb shell pm list packages $packageName | Out-String).Trim()
        if ($installed) { Invoke-Adb shell pm clear $packageName | Out-Null }
    }
    Build-DebugApks
    $apk = Join-Path $androidRoot 'app\build\outputs\apk\debug\app-debug.apk'
    Install-Apk $apk
    if ($GrantCamera) { Invoke-Adb shell pm grant $packageName android.permission.CAMERA }
}

function Enable-UsbRoute {
    Resolve-Device
    Invoke-Adb reverse "tcp:$Port" "tcp:$Port"
    Write-Host "USB route ready. Android app: host=127.0.0.1 port=$Port"
}

function Show-LanRoute {
    $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -ExpandProperty IPAddress -Unique
    Write-Host "Android app port: $Port"
    Write-Host 'PC IPv4 candidates:'
    $addresses | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Windows Firewallで、このポートのプライベートネットワーク受信を許可してください。'
}

function Start-App {
    Resolve-Device
    Invoke-Adb shell am start -n "$packageName/.MainActivity" | Out-Host
}

function Invoke-InstrumentedTest {
    Resolve-Device
    Install-App
    Build-DebugApks -IncludeTest
    $testApk = Join-Path $androidRoot 'app\build\outputs\apk\androidTest\debug\app-debug-androidTest.apk'
    Install-Apk $testApk
    Invoke-Adb shell am instrument -w "$packageName.test/androidx.test.runner.AndroidJUnitRunner" | Out-Host
}

function Get-BatterySample {
    $text = Invoke-Adb shell dumpsys battery | Out-String
    $level = [regex]::Match($text, '(?m)^\s*level:\s*(\d+)').Groups[1].Value
    $temperature = [regex]::Match($text, '(?m)^\s*temperature:\s*(\d+)').Groups[1].Value
    [pscustomobject]@{ level = $level; temperatureC = if ($temperature) { [double]$temperature / 10 } else { $null } }
}

function Invoke-Soak {
    Resolve-Device
    New-ResultDirectory
    Start-App
    $logFile = Join-Path $OutputDirectory 'logcat.txt'
    $logError = Join-Path $OutputDirectory 'logcat-error.txt'
    $metricsFile = Join-Path $OutputDirectory 'device-metrics.csv'
    Invoke-Adb logcat -c
    $arguments = @('-s', $Serial, 'logcat', '-v', 'threadtime', 'YubiBoardDiag:I', 'AndroidRuntime:E', '*:S')
    $logProcess = Start-Process -FilePath $adb -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $logFile -RedirectStandardError $logError
    $started = Get-Date
    try {
        while (((Get-Date) - $started).TotalMinutes -lt $DurationMinutes) {
            $battery = Get-BatterySample
            $appProcessId = (Invoke-Adb shell pidof $packageName | Out-String).Trim()
            $memoryKb = $null
            if ($appProcessId) {
                $meminfo = Invoke-Adb shell dumpsys meminfo $packageName | Out-String
                $memoryKb = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(\d+)').Groups[1].Value
            }
            $cpuInfo = Invoke-Adb shell dumpsys cpuinfo | Out-String
            $cpuPercent = [regex]::Match(
                $cpuInfo,
                "(?m)^\s*([0-9.]+)%\s+\d+/$([regex]::Escape($packageName))"
            ).Groups[1].Value
            [pscustomobject]@{
                timestamp = [DateTime]::UtcNow.ToString('o')
                elapsedSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
                pid = $appProcessId
                memoryKb = $memoryKb
                cpuPercent = $cpuPercent
                batteryLevel = $battery.level
                temperatureC = $battery.temperatureC
            } | Export-Csv -LiteralPath $metricsFile -NoTypeInformation -Encoding utf8 -Append
            Start-Sleep -Seconds 5
        }
    } finally {
        if (-not $logProcess.HasExited) { Stop-Process -Id $logProcess.Id }
        Start-Sleep -Milliseconds 300
        Invoke-Adb shell dumpsys meminfo $packageName | Set-Content -LiteralPath (Join-Path $OutputDirectory 'meminfo-final.txt') -Encoding utf8
        Invoke-Adb shell dumpsys gfxinfo $packageName | Set-Content -LiteralPath (Join-Path $OutputDirectory 'gfxinfo-final.txt') -Encoding utf8
        Invoke-Adb shell dumpsys thermalservice | Set-Content -LiteralPath (Join-Path $OutputDirectory 'thermal-final.txt') -Encoding utf8
    }
    $rows = Import-Csv -LiteralPath $metricsFile
    $crashCount = if (Test-Path $logFile) { @(Select-String -LiteralPath $logFile -Pattern 'FATAL EXCEPTION|ANR in').Count } else { 0 }
    $diagnosticEvents = @()
    if (Test-Path $logFile) {
        foreach ($line in Get-Content -LiteralPath $logFile) {
            $jsonStart = $line.IndexOf('{')
            if ($jsonStart -lt 0) { continue }
            try { $diagnosticEvents += $line.Substring($jsonStart) | ConvertFrom-Json } catch { }
        }
    }
    function Format-MetricSummary {
        param([double[]]$Values)
        if ($Values.Count -eq 0) { return 'n/a' }
        $sorted = @($Values | Sort-Object)
        $p50 = $sorted[[Math]::Min($sorted.Count - 1, [Math]::Floor($sorted.Count * 0.50))]
        $p95 = $sorted[[Math]::Min($sorted.Count - 1, [Math]::Floor($sorted.Count * 0.95))]
        $average = ($sorted | Measure-Object -Average).Average
        return "n=$($sorted.Count), avg=$([Math]::Round($average,2)), p50=$p50, p95=$p95"
    }
    $fpsValues = @($diagnosticEvents | Where-Object { $_.name -eq 'hand_result' } | ForEach-Object { [double]$_.fields.fps })
    $inferenceValues = @($diagnosticEvents | Where-Object { $_.name -eq 'hand_result' } | ForEach-Object { [double]$_.fields.inferenceMs })
    $sendLatencyValues = @($diagnosticEvents | Where-Object { $_.name -eq 'hand_frame_sent' } | ForEach-Object { [double]$_.fields.captureToSendMs })
    @(
        '# YubiBoard device soak summary'
        ''
        "- Serial: $Serial"
        "- Duration: $DurationMinutes minutes"
        "- Samples: $($rows.Count)"
        "- Start temperature: $($rows[0].temperatureC) C"
        "- End temperature: $($rows[-1].temperatureC) C"
        "- Start memory: $($rows[0].memoryKb) KiB"
        "- End memory: $($rows[-1].memoryKb) KiB"
        "- Hand fps: $(Format-MetricSummary $fpsValues)"
        "- Inference ms: $(Format-MetricSummary $inferenceValues)"
        "- Capture-to-send ms: $(Format-MetricSummary $sendLatencyValues)"
        "- Crash/ANR matches: $crashCount"
    ) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding utf8
    Write-Host "Results: $OutputDirectory"
}

switch ($Action) {
    'doctor' { Invoke-Doctor }
    'build' { Invoke-Build }
    'install' { Install-App }
    'usb' { Enable-UsbRoute }
    'lan' { Show-LanRoute }
    'test' { Invoke-InstrumentedTest }
    'start' { Start-App }
    'soak' { Invoke-Soak }
    'all' {
        Invoke-Doctor
        Invoke-Build
        Enable-UsbRoute
        Invoke-InstrumentedTest
        Start-App
    }
}
