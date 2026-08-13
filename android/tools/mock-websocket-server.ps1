param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidatePattern('^[0-9]{6}$')]
    [string]$PairingToken = '123456',

    [ValidateSet('tracking', 'calibration')]
    [string]$InitialMode = 'tracking',

    [ValidateSet(
        'happy', 'production-happy', 'calibration-retry', 'pairing-rejected',
        'unsupported-version', 'server-busy', 'mode-switch', 'remote-disconnect',
        'ack-timeout', 'invalid-json', 'wrong-session', 'schema-mismatch', 'drop', 'slow-reader',
        'resume-token-invalid'
    )]
    [string]$Scenario = 'happy',

    [ValidateRange(0, 3600)]
    [int]$DurationSeconds = 0,

    [ValidateRange(0, 5000)]
    [int]$ReadDelayMs = 0,

    [string]$OutputDirectory = '',

    [string]$TrustStorePath = '',

    [switch]$ResetTrustStore,

    [switch]$AutoPlacementOk,

    [switch]$RenderVideo,

    [ValidateRange(2, 3840)]
    [int]$VideoWidth = 960,

    [ValidateRange(2, 2160)]
    [int]$VideoHeight = 540,

    [ValidateRange(1, 120)]
    [int]$VideoFps = 20
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.Encoding]::UTF8
$webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
$runStartedAt = [DateTime]::UtcNow

function Test-RunExpired {
    return $DurationSeconds -gt 0 -and
        ([DateTime]::UtcNow - $runStartedAt).TotalSeconds -ge $DurationSeconds
}

function New-ResumeToken {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Save-TrustedDevices {
    $script:trustedDevices | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $TrustStorePath -Encoding utf8
}

function Test-MessageProperty {
    param([object]$Message, [string]$Name)
    $property = $Message.PSObject.Properties[$Name]
    return $null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)
}

function Test-FiniteNumber {
    param([object]$Value)
    try {
        $number = [double]$Value
        return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
    } catch {
        return $false
    }
}

function Add-HandValidationErrors {
    param([object]$Hand, [string]$Prefix, [object]$Errors)
    if ($null -eq $Hand) { $Errors.Add("$Prefix is required"); return }
    if ([int]$Hand.trackId -le 0) { $Errors.Add("$Prefix.trackId must be a positive integer") }
    if ($Hand.coordinateSpace -ne 'normalized_camera') { $Errors.Add("$Prefix.coordinateSpace is invalid") }
    if ($Hand.landmarkFormat -ne 'mediapipe_hand_21') { $Errors.Add("$Prefix.landmarkFormat is invalid") }
    if ($Hand.landmarks.Count -ne 21) { $Errors.Add("$Prefix must contain 21 landmarks"); return }
    for ($index = 0; $index -lt $Hand.landmarks.Count; $index++) {
        $point = $Hand.landmarks[$index]
        if ($point.Count -ne 3) { $Errors.Add("$Prefix.landmarks[$index] must contain x,y,z"); continue }
        if (-not (Test-FiniteNumber $point[0]) -or -not (Test-FiniteNumber $point[1]) -or
            -not (Test-FiniteNumber $point[2])) {
            $Errors.Add("$Prefix.landmarks[$index] must be finite")
            continue
        }
        if ([double]$point[0] -lt 0 -or [double]$point[0] -gt 1 -or
            [double]$point[1] -lt 0 -or [double]$point[1] -gt 1) {
            $Errors.Add("$Prefix.landmarks[$index] x/y is outside normalized range")
        }
    }
    if ($null -ne $Hand.handednessScore -and
        (-not (Test-FiniteNumber $Hand.handednessScore) -or
            [double]$Hand.handednessScore -lt 0 -or [double]$Hand.handednessScore -gt 1)) {
        $Errors.Add("$Prefix.handednessScore must be between 0 and 1")
    }
}

function Read-ExactBytes {
    param(
        [System.IO.Stream]$Stream,
        [int]$Count
    )
    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        try {
            $read = $Stream.Read($buffer, $offset, $Count - $offset)
        } catch [System.IO.IOException] {
            $socketError = $_.Exception.InnerException -as [System.Net.Sockets.SocketException]
            if ($null -ne $socketError -and
                $socketError.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                if (Test-RunExpired) { throw [TimeoutException]::new('Server duration complete') }
                continue
            }
            throw
        }
        if ($read -le 0) { throw 'Client disconnected' }
        $offset += $read
    }
    return ,$buffer
}

function Read-HttpHeaders {
    param([System.IO.Stream]$Stream)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($bytes.Count -lt 8192) {
        $value = Read-ExactBytes -Stream $Stream -Count 1
        $bytes.Add($value[0])
        $count = $bytes.Count
        if ($count -ge 4 -and
            $bytes[$count - 4] -eq 13 -and $bytes[$count - 3] -eq 10 -and
            $bytes[$count - 2] -eq 13 -and $bytes[$count - 1] -eq 10) {
            return $utf8.GetString($bytes.ToArray())
        }
    }
    throw 'WebSocket handshake exceeded 8 KiB'
}

function Complete-WebSocketHandshake {
    param([System.IO.Stream]$Stream)
    $headers = Read-HttpHeaders -Stream $Stream
    $keyLine = ($headers -split "`r`n" | Where-Object { $_ -match '^Sec-WebSocket-Key:' } | Select-Object -First 1)
    if (-not $keyLine) { throw 'Sec-WebSocket-Key was not supplied' }
    $key = ($keyLine -split ':', 2)[1].Trim()
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $accept = [Convert]::ToBase64String($sha1.ComputeHash($utf8.GetBytes($key + $webSocketGuid)))
    } finally {
        $sha1.Dispose()
    }
    $response = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Accept: $accept`r`n`r`n"
    $responseBytes = $utf8.GetBytes($response)
    $Stream.Write($responseBytes, 0, $responseBytes.Length)
}

function Read-WebSocketFrame {
    param([System.IO.Stream]$Stream)
    $header = Read-ExactBytes -Stream $Stream -Count 2
    $opcode = $header[0] -band 0x0F
    $masked = ($header[1] -band 0x80) -ne 0
    [long]$length = $header[1] -band 0x7F
    if ($length -eq 126) {
        $extended = Read-ExactBytes -Stream $Stream -Count 2
        # PowerShell preserves the byte type for bit shifts, so cast before
        # shifting to avoid truncating payload lengths above 255 bytes.
        $length = (([int]$extended[0]) -shl 8) -bor ([int]$extended[1])
    } elseif ($length -eq 127) {
        $extended = Read-ExactBytes -Stream $Stream -Count 8
        $length = 0
        foreach ($value in $extended) { $length = ($length -shl 8) -bor $value }
    }
    if ($length -gt 1048576) { throw 'Frame exceeds 1 MiB test-server limit' }
    $mask = if ($masked) { Read-ExactBytes -Stream $Stream -Count 4 } else { $null }
    $payload = Read-ExactBytes -Stream $Stream -Count ([int]$length)
    if ($masked) {
        for ($index = 0; $index -lt $payload.Length; $index++) {
            $payload[$index] = $payload[$index] -bxor $mask[$index % 4]
        }
    }
    return [pscustomobject]@{ Opcode = $opcode; Payload = $payload }
}

function Send-WebSocketFrame {
    param(
        [System.IO.Stream]$Stream,
        [ValidateRange(0, 15)]
        [int]$Opcode,
        [byte[]]$Payload
    )
    $header = [System.Collections.Generic.List[byte]]::new()
    $header.Add([byte](0x80 -bor $Opcode))
    if ($Payload.Length -lt 126) {
        $header.Add([byte]$Payload.Length)
    } elseif ($Payload.Length -le 65535) {
        $header.Add(126)
        $header.Add([byte](($Payload.Length -shr 8) -band 0xFF))
        $header.Add([byte]($Payload.Length -band 0xFF))
    } else {
        throw 'Server response is too large'
    }
    $headerBytes = $header.ToArray()
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($Payload, 0, $Payload.Length)
}

function Send-WebSocketText {
    param(
        [System.IO.Stream]$Stream,
        [string]$Text
    )
    Send-WebSocketFrame -Stream $Stream -Opcode 1 -Payload $utf8.GetBytes($Text)
}

function Send-HelloError {
    param(
        [System.IO.Stream]$Stream,
        [string]$Code,
        [bool]$Retryable
    )
    $payload = [ordered]@{
        schemaVersion = 1
        messageType = 'hello_error'
        code = $Code
        retryable = $Retryable
    } | ConvertTo-Json -Compress
    Send-WebSocketText -Stream $Stream -Text $payload
    Write-DebugEvent -Name 'hello_error_sent' -Data @{ code = $Code; retryable = $Retryable }
}

function Send-CalibrationStatus {
    param(
        [System.IO.Stream]$Stream,
        [string]$SessionId,
        [ValidateSet('processing', 'retry_required', 'complete')]
        [string]$Status,
        [string]$Reason = ''
    )
    $payload = [ordered]@{
        schemaVersion = 1
        messageType = 'calibration_status'
        sessionId = $SessionId
        status = $Status
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $payload.reason = $Reason }
    Send-WebSocketText -Stream $Stream -Text ($payload | ConvertTo-Json -Compress)
    Write-DebugEvent -Name 'calibration_status_sent' -Data @{ status = $Status; reason = $Reason }
}

function Send-ModeControl {
    param(
        [System.IO.Stream]$Stream,
        [string]$SessionId,
        [ValidateSet('tracking', 'calibration')]
        [string]$Mode
    )
    $payload = [ordered]@{
        schemaVersion = 1
        messageType = 'control_message'
        sessionId = $SessionId
        command = 'set_mode'
        mode = $Mode
    } | ConvertTo-Json -Compress
    Send-WebSocketText -Stream $Stream -Text $payload
    Write-DebugEvent -Name 'control_sent' -Data @{ command = 'set_mode'; mode = $Mode }
}

function Write-DebugEvent {
    param(
        [string]$Name,
        [hashtable]$Data = @{}
    )
    $entry = [ordered]@{
        receivedAtUtc = [DateTime]::UtcNow.ToString('o')
        event = $Name
        data = $Data
    }
    ($entry | ConvertTo-Json -Compress -Depth 12) | Add-Content -LiteralPath $script:eventLog -Encoding utf8
}

function Write-HandFrame {
    param([object]$Message)
    $entry = [ordered]@{
        receivedAtUtc = [DateTime]::UtcNow.ToString('o')
        message = $Message
    }
    ($entry | ConvertTo-Json -Compress -Depth 12) | Add-Content -LiteralPath $script:handFrameLog -Encoding utf8
}

function Test-ClientMessage {
    param(
        [object]$Message,
        [string]$ActiveSession
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Message.schemaVersion -ne 1) { $errors.Add('schemaVersion must be 1') }
    switch ($Message.messageType) {
        'hello' {
            if (-not $Message.deviceId) { $errors.Add('hello.deviceId is required') }
            if ($Message.coordinateSpace -ne 'normalized_camera') { $errors.Add('hello.coordinateSpace is invalid') }
            $hasPairing = Test-MessageProperty -Message $Message -Name 'pairingToken'
            $hasResume = Test-MessageProperty -Message $Message -Name 'resumeToken'
            if ($hasPairing -eq $hasResume) {
                $errors.Add('hello must contain exactly one of pairingToken or resumeToken')
            } elseif ($hasPairing -and $Message.pairingToken -notmatch '^[0-9]{6}$') {
                $errors.Add('hello.pairingToken must be six digits')
            }
            if ($Message.interactionProfile -eq 'two_users_two_active_hands') {
                if ([int]$Message.maxHands -ne 2) { $errors.Add('hello.maxHands must be 2') }
                foreach ($capability in @('hand_landmarks_21', 'multi_hand_landmarks_21', 'stable_hand_track_id')) {
                    if ($capability -notin @($Message.capabilities)) {
                        $errors.Add("hello.capabilities must include $capability")
                    }
                }
            }
        }
        'hand_frame' {
            if ($Message.sessionId -ne $ActiveSession) { $errors.Add('hand_frame.sessionId does not match') }
            if ($null -eq $Message.PSObject.Properties['hands']) {
                $errors.Add('hand_frame.hands is required')
            } else {
                $hands = @($Message.hands)
                if ($hands.Count -gt 2) { $errors.Add('hand_frame.hands must contain at most 2 hands') }
                $ids = @($hands | ForEach-Object { [int]$_.trackId })
                if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
                    $errors.Add('hand_frame.hands contains duplicate trackId')
                }
                for ($handIndex = 0; $handIndex -lt $hands.Count; $handIndex++) {
                    Add-HandValidationErrors -Hand $hands[$handIndex] -Prefix "hand_frame.hands[$handIndex]" -Errors $errors
                }
            }
            if ($null -eq $Message.hand.detected) { $errors.Add('hand_frame.hand.detected is required') }
            if ($Message.hand.detected) {
                if ($Message.hand.landmarks.Count -ne 21) { $errors.Add('detected hand must contain 21 landmarks') }
                for ($index = 0; $index -lt $Message.hand.landmarks.Count; $index++) {
                    $point = $Message.hand.landmarks[$index]
                    if ($point.Count -ne 3) { $errors.Add("landmark $index must contain x,y,z"); continue }
                    if ([double]$point[0] -lt 0 -or [double]$point[0] -gt 1 -or [double]$point[1] -lt 0 -or [double]$point[1] -gt 1) {
                        $errors.Add("landmark $index x/y is outside normalized range")
                    }
                }
            } elseif ($null -ne $Message.hand.landmarks) {
                $errors.Add('missing hand must omit landmarks')
            }
            if ($null -ne $Message.PSObject.Properties['hands']) {
                $hands = @($Message.hands)
                if ($hands.Count -eq 0 -and $Message.hand.detected) {
                    $errors.Add('legacy hand must be undetected when hands is empty')
                } elseif ($hands.Count -gt 0) {
                    $primary = $hands | Sort-Object { [int]$_.trackId } | Select-Object -First 1
                    if (-not $Message.hand.detected -or
                        ($Message.hand.landmarks | ConvertTo-Json -Compress -Depth 5) -ne
                            ($primary.landmarks | ConvertTo-Json -Compress -Depth 5)) {
                        $errors.Add('legacy hand must copy the lowest trackId hand')
                    }
                }
            }
        }
        'calibration_markers' {
            if ($Message.sessionId -ne $ActiveSession) { $errors.Add('calibration_markers.sessionId does not match') }
            $ids = @($Message.markers | ForEach-Object { [int]$_.id } | Sort-Object)
            if (($ids -join ',') -ne '10,11,12,13') { $errors.Add('calibration markers must be IDs 10,11,12,13') }
            foreach ($marker in $Message.markers) {
                if ($marker.center.Count -ne 2 -or $marker.corners.Count -ne 4) {
                    $errors.Add("marker $($marker.id) must contain center and four corners")
                }
            }
        }
        'heartbeat' {
            if ($Message.sessionId -ne $ActiveSession) { $errors.Add('heartbeat.sessionId does not match') }
        }
        default { $errors.Add("unknown messageType: $($Message.messageType)") }
    }
    return @($errors)
}

function Write-ServerSummary {
    if (-not (Test-Path -LiteralPath $summaryFile)) { return }
    $rows = @(Import-Csv -LiteralPath $summaryFile)
    $handFrames = ($rows | Measure-Object -Property handFrames -Sum).Sum
    $twoHandFrames = ($rows | Measure-Object -Property twoHandFrames -Sum).Sum
    $maxHandsSeen = ($rows | Measure-Object -Property maxHandsSeen -Maximum).Maximum
    $invalidItems = ($rows | Measure-Object -Property invalidItems -Sum).Sum
    $bytes = ($rows | Measure-Object -Property receivedBytes -Sum).Sum
    @(
        '# YubiBoard mock server summary'
        ''
        "- Scenario: $Scenario"
        "- Connections: $($rows.Count)"
        "- Hand frames: $handFrames"
        "- Two-hand frames: $twoHandFrames"
        "- Maximum simultaneous hands: $maxHandsSeen"
        "- Validation errors: $invalidItems"
        "- Received bytes: $bytes"
        "- Generated at: $([DateTime]::UtcNow.ToString('o'))"
    ) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding utf8
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "debug-results\server-$stamp"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if ([string]::IsNullOrWhiteSpace($TrustStorePath)) {
    $TrustStorePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-results\mock-trusted-devices.json'
}
$TrustStorePath = [System.IO.Path]::GetFullPath($TrustStorePath)
if ($ResetTrustStore -and (Test-Path -LiteralPath $TrustStorePath)) {
    Remove-Item -LiteralPath $TrustStorePath -Force
}
$script:trustedDevices = @{}
if (Test-Path -LiteralPath $TrustStorePath) {
    $loadedTrust = Get-Content -Raw -LiteralPath $TrustStorePath | ConvertFrom-Json -AsHashtable
    if ($null -ne $loadedTrust) { $script:trustedDevices = $loadedTrust }
}
$script:eventLog = Join-Path $OutputDirectory 'events.jsonl'
$script:handFrameLog = Join-Path $OutputDirectory 'hand-frames.jsonl'
$summaryFile = Join-Path $OutputDirectory 'connections.csv'
$effectiveReadDelayMs = if ($Scenario -eq 'slow-reader' -and $ReadDelayMs -eq 0) { 500 } else { $ReadDelayMs }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Start()
$calibrationComplete = $false
Write-Host "YubiBoard mock WebSocket server: 0.0.0.0:$Port/ws/v1/input"
Write-Host "Pairing token: $PairingToken / initial mode: $InitialMode / scenario: $Scenario"
Write-Host "Results: $OutputDirectory"
Write-Host "Debug trust store: $TrustStorePath"
Write-Host "Hand coordinates: $script:handFrameLog"
Write-Host 'Stop with Ctrl+C.'
Write-DebugEvent -Name 'server_started' -Data @{
    port = $Port
    scenario = $Scenario
    initialMode = $InitialMode
    trustedDeviceCount = $script:trustedDevices.Count
}

try {
    while (-not (Test-RunExpired)) {
        while (-not $listener.Pending()) {
            if (Test-RunExpired) { break }
            Start-Sleep -Milliseconds 100
        }
        if (Test-RunExpired) { break }
        $client = $listener.AcceptTcpClient()
        $remote = $client.Client.RemoteEndPoint
        $sessionId = $null
        $connectionStartedAt = $null
        $frameCount = 0
        $missingCount = 0
        $twoHandFrameCount = 0
        $maxHandsSeen = 0
        $seenTrackIds = [System.Collections.Generic.HashSet[int]]::new()
        $markerCount = 0
        $heartbeatCount = 0
        $invalidCount = 0
        $gapCount = 0
        $bytesReceived = 0L
        Write-Host "Client connected: $remote"
        try {
            $stream = $client.GetStream()
            # Short reads let PowerShell process Ctrl+C instead of remaining in a
            # blocking .NET socket call indefinitely.
            $stream.ReadTimeout = 250
            Complete-WebSocketHandshake -Stream $stream
            $sessionId = 'session-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $frameCount = 0
            $missingCount = 0
            $twoHandFrameCount = 0
            $maxHandsSeen = 0
            $seenTrackIds = [System.Collections.Generic.HashSet[int]]::new()
            $markerCount = 0
            $heartbeatCount = 0
            $invalidCount = 0
            $gapCount = 0
            $bytesReceived = 0L
            $lastFrameId = $null
            $connectionStartedAt = [DateTime]::UtcNow
            $scenarioActionSent = $false
            Write-DebugEvent -Name 'client_connected' -Data @{ remote = $remote.ToString(); sessionId = $sessionId }
            while ($client.Connected -and -not (Test-RunExpired)) {
                $frame = Read-WebSocketFrame -Stream $stream
                if ($effectiveReadDelayMs -gt 0) { Start-Sleep -Milliseconds $effectiveReadDelayMs }
                if ($frame.Opcode -eq 8) {
                    Send-WebSocketFrame -Stream $stream -Opcode 8 -Payload $frame.Payload
                    break
                }
                if ($frame.Opcode -eq 9) {
                    Send-WebSocketFrame -Stream $stream -Opcode 10 -Payload $frame.Payload
                    continue
                }
                if ($frame.Opcode -ne 1) { continue }
                $text = $utf8.GetString($frame.Payload)
                $bytesReceived += $frame.Payload.Length
                try {
                    $message = $text | ConvertFrom-Json
                } catch {
                    $invalidCount++
                    Write-DebugEvent -Name 'invalid_client_json' -Data @{ text = $text; error = $_.Exception.Message }
                    continue
                }
                $validationErrors = @(Test-ClientMessage -Message $message -ActiveSession $sessionId)
                if ($validationErrors.Count -gt 0) {
                    $invalidCount += $validationErrors.Count
                    Write-DebugEvent -Name 'validation_error' -Data @{ messageType = $message.messageType; errors = $validationErrors }
                    continue
                }
                Write-DebugEvent -Name 'message_received' -Data @{ messageType = $message.messageType; bytes = $frame.Payload.Length; frameId = $message.frameId }
                switch ($message.messageType) {
                    'hello' {
                        $hasPairing = Test-MessageProperty -Message $message -Name 'pairingToken'
                        $hasResume = Test-MessageProperty -Message $message -Name 'resumeToken'
                        $issuedResumeToken = $null
                        if ($hasPairing -eq $hasResume) {
                            Send-HelloError -Stream $stream -Code 'pairing_code_mismatch' -Retryable $false
                            break
                        }
                        if ($hasPairing) {
                            if ($message.pairingToken -ne $PairingToken -or $Scenario -eq 'pairing-rejected') {
                                Write-Warning "Rejected pairing token from $remote"
                                Send-HelloError -Stream $stream -Code 'pairing_code_mismatch' -Retryable $false
                                break
                            }
                            $issuedResumeToken = New-ResumeToken
                        } else {
                            $savedResumeToken = [string]$script:trustedDevices[[string]$message.deviceId]
                            if ($Scenario -eq 'resume-token-invalid' -or
                                [string]::IsNullOrWhiteSpace($savedResumeToken) -or
                                $message.resumeToken -cne $savedResumeToken) {
                                Write-Warning "Rejected trusted connection from $remote"
                                Send-HelloError -Stream $stream -Code 'resume_token_invalid' -Retryable $false
                                break
                            }
                            Write-DebugEvent -Name 'trusted_device_resumed' -Data @{ deviceId = $message.deviceId }
                        }
                        if ($Scenario -eq 'unsupported-version') {
                            Send-HelloError -Stream $stream -Code 'unsupported_version' -Retryable $false
                            break
                        }
                        if ($Scenario -eq 'server-busy') {
                            Send-HelloError -Stream $stream -Code 'server_busy' -Retryable $true
                            break
                        }
                        if ($Scenario -eq 'ack-timeout') {
                            Write-Host 'Scenario ack-timeout: hello_ack suppressed'
                            continue
                        }
                        if ($null -ne $issuedResumeToken) {
                            $script:trustedDevices[[string]$message.deviceId] = $issuedResumeToken
                            Save-TrustedDevices
                            Write-DebugEvent -Name 'trusted_device_issued' -Data @{ deviceId = $message.deviceId }
                        }
                        $ackSchemaVersion = if ($Scenario -eq 'schema-mismatch') { 99 } else { 1 }
                        $calibrationRequired = -not $calibrationComplete -and (
                            $InitialMode -eq 'calibration' -or
                            $Scenario -in @('production-happy', 'calibration-retry')
                        )
                        $ack = [ordered]@{
                            schemaVersion = $ackSchemaVersion
                            messageType = 'hello_ack'
                            sessionId = $sessionId
                            surface = [ordered]@{ surfaceId = 'mock-display'; widthPx = 1920; heightPx = 1080 }
                            calibrationRequired = $calibrationRequired
                        }
                        if ($message.interactionProfile -eq 'two_users_two_active_hands') {
                            $ack.acceptedInteractionProfile = 'two_users_two_active_hands'
                        }
                        if ($null -ne $issuedResumeToken) { $ack.resumeToken = $issuedResumeToken }
                        Send-WebSocketText -Stream $stream -Text ($ack | ConvertTo-Json -Compress)
                        Write-Host "Handshake accepted: $sessionId"
                        Write-DebugEvent -Name 'hello_ack_sent' -Data @{
                            sessionId = $sessionId
                            schemaVersion = $ackSchemaVersion
                            calibrationRequired = $calibrationRequired
                            resumeTokenIssued = $null -ne $issuedResumeToken
                        }
                        if ($calibrationRequired) {
                            Write-Host 'Androidへスマホ固定を案内しました。固定後にPC側の配置OKを実行します。'
                            if ($AutoPlacementOk) {
                                Start-Sleep -Milliseconds 500
                                Write-Host '配置OK（自動）: ArUcoターゲットを全画面表示してください。'
                            } else {
                                Read-Host 'スマホを固定したらEnterを押してください（PCの配置OK）'
                                Write-Host '配置OK: ArUcoターゲットを全画面表示してください。'
                            }
                            Write-DebugEvent -Name 'placement_ok' -Data @{ automatic = [bool]$AutoPlacementOk }
                        }
                        if ($Scenario -eq 'invalid-json') {
                            Send-WebSocketText -Stream $stream -Text '{not-valid-json'
                        } elseif ($Scenario -eq 'wrong-session') {
                            $control = [ordered]@{ schemaVersion = 1; messageType = 'control_message'; sessionId = 'wrong-session'; command = 'set_mode'; mode = 'calibration' } | ConvertTo-Json -Compress
                            Send-WebSocketText -Stream $stream -Text $control
                        }
                    }
                    'hand_frame' {
                        Write-HandFrame -Message $message
                        $frameCount++
                        $handCount = @($message.hands).Count
                        if ($handCount -eq 2) { $twoHandFrameCount++ }
                        $maxHandsSeen = [Math]::Max($maxHandsSeen, $handCount)
                        foreach ($handItem in @($message.hands)) {
                            [void]$seenTrackIds.Add([int]$handItem.trackId)
                        }
                        if (-not $message.hand.detected) { $missingCount++ }
                        if ($null -ne $lastFrameId -and [long]$message.frameId -gt [long]$lastFrameId + 1) {
                            $gapCount += [long]$message.frameId - [long]$lastFrameId - 1
                        }
                        $lastFrameId = [long]$message.frameId
                        if ($frameCount -eq 1 -or $frameCount % 20 -eq 0) {
                            $indexTip = if ($message.hand.detected -and $message.hand.landmarks.Count -eq 21) {
                                $point = $message.hand.landmarks[8]
                                ", index_tip=($($point[0]), $($point[1]), $($point[2]))"
                            } else {
                                ''
                            }
                            Write-Host "hand_frame #$($message.frameId): hands=$handCount, trackIds=$(@($message.hands.trackId) -join ','), received=$frameCount$indexTip"
                        }
                    }
                    'calibration_markers' {
                        $markerCount++
                        Write-Host "calibration_markers: $($message.markers.Count)/4"
                        if ($Scenario -eq 'production-happy' -and -not $scenarioActionSent) {
                            Send-CalibrationStatus -Stream $stream -SessionId $sessionId -Status processing
                            Start-Sleep -Milliseconds 500
                            Send-CalibrationStatus -Stream $stream -SessionId $sessionId -Status complete
                            $calibrationComplete = $true
                            Send-ModeControl -Stream $stream -SessionId $sessionId -Mode tracking
                            $scenarioActionSent = $true
                        } elseif ($Scenario -eq 'calibration-retry' -and $markerCount -eq 1) {
                            Send-CalibrationStatus -Stream $stream -SessionId $sessionId -Status processing
                            Start-Sleep -Milliseconds 300
                            Send-CalibrationStatus -Stream $stream -SessionId $sessionId -Status retry_required -Reason invalid_geometry
                        } elseif ($Scenario -eq 'calibration-retry' -and $markerCount -ge 2 -and -not $scenarioActionSent) {
                            Send-CalibrationStatus -Stream $stream -SessionId $sessionId -Status processing
                            Start-Sleep -Milliseconds 500
                            Send-CalibrationStatus -Stream $stream -SessionId $sessionId -Status complete
                            $calibrationComplete = $true
                            Send-ModeControl -Stream $stream -SessionId $sessionId -Mode tracking
                            $scenarioActionSent = $true
                        }
                    }
                    'heartbeat' {
                        $heartbeatCount++
                        Write-Verbose "heartbeat: $($message.sentAtMonotonicMs)"
                    }
                    default {
                        Write-Warning "Unknown message type: $($message.messageType)"
                    }
                }
                $elapsed = ([DateTime]::UtcNow - $connectionStartedAt).TotalSeconds
                if (-not $scenarioActionSent -and $elapsed -ge 3) {
                    if ($Scenario -eq 'mode-switch') {
                        $nextMode = if ($InitialMode -eq 'tracking') { 'calibration' } else { 'tracking' }
                        $control = [ordered]@{ schemaVersion = 1; messageType = 'control_message'; sessionId = $sessionId; command = 'set_mode'; mode = $nextMode } | ConvertTo-Json -Compress
                        Send-WebSocketText -Stream $stream -Text $control
                        Write-DebugEvent -Name 'control_sent' -Data @{ command = 'set_mode'; mode = $nextMode }
                        $scenarioActionSent = $true
                    } elseif ($Scenario -eq 'remote-disconnect') {
                        $control = [ordered]@{ schemaVersion = 1; messageType = 'control_message'; sessionId = $sessionId; command = 'disconnect' } | ConvertTo-Json -Compress
                        Send-WebSocketText -Stream $stream -Text $control
                        Write-DebugEvent -Name 'control_sent' -Data @{ command = 'disconnect' }
                        $scenarioActionSent = $true
                    } elseif ($Scenario -eq 'drop') {
                        Write-DebugEvent -Name 'connection_dropped' -Data @{}
                        $client.Dispose()
                        $scenarioActionSent = $true
                        break
                    }
                }
            }
        } catch [System.Management.Automation.PipelineStoppedException] {
            # Ctrl+C must escape the client loop so the listener is released by
            # the outer finally block.
            throw
        } catch {
            if (-not (Test-RunExpired)) {
                Write-Warning $_.Exception.Message
                Write-DebugEvent -Name 'client_error' -Data @{ remote = $remote.ToString(); error = $_.Exception.Message }
            }
        } finally {
            if ($null -ne $connectionStartedAt) {
                $duration = [Math]::Max(0.001, ([DateTime]::UtcNow - $connectionStartedAt).TotalSeconds)
                [pscustomobject]@{
                    startedAtUtc = $connectionStartedAt.ToString('o')
                    remote = $remote.ToString()
                    sessionId = $sessionId
                    durationSeconds = [Math]::Round($duration, 3)
                    handFrames = $frameCount
                    twoHandFrames = $twoHandFrameCount
                    maxHandsSeen = $maxHandsSeen
                    trackIds = (@($seenTrackIds) | Sort-Object) -join ','
                    missingFrames = $missingCount
                    calibrationMessages = $markerCount
                    heartbeats = $heartbeatCount
                    invalidItems = $invalidCount
                    frameIdGaps = $gapCount
                    receivedBytes = $bytesReceived
                    receiveFps = [Math]::Round($frameCount / $duration, 3)
            } | Export-Csv -LiteralPath $summaryFile -NoTypeInformation -Encoding utf8 -Append
                Write-ServerSummary
            }
            $client.Dispose()
            Write-Host "Client disconnected: $remote"
        }
    }
} finally {
    $listener.Stop()
    Write-DebugEvent -Name 'server_stopped' -Data @{}
    Write-ServerSummary
    if ($RenderVideo) {
        if (-not (Test-Path -LiteralPath $script:handFrameLog)) {
            Write-Warning 'No hand frames were received; video was not generated.'
        } elseif (($VideoWidth % 2) -ne 0 -or ($VideoHeight % 2) -ne 0) {
            Write-Warning 'VideoWidth and VideoHeight must be even; video was not generated.'
        } else {
            $python = @(Get-Command python -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($null -eq $python) {
                Write-Warning 'Python was not found; run render_hand_video.py manually after installing Python 3.'
            } else {
                $renderer = Join-Path $PSScriptRoot 'render_hand_video.py'
                $video = Join-Path $OutputDirectory 'hand-tracking.mp4'
                & $python.Source $renderer $script:handFrameLog $video --width $VideoWidth --height $VideoHeight --fps $VideoFps
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Video renderer exited with status $LASTEXITCODE. The coordinate log remains at $script:handFrameLog"
                }
            }
        }
    }
}
