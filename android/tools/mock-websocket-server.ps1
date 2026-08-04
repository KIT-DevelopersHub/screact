param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidatePattern('^[0-9]{6}$')]
    [string]$PairingToken = '123456',

    [ValidateSet('tracking', 'calibration')]
    [string]$InitialMode = 'tracking',

    [ValidateSet('happy', 'mode-switch', 'remote-disconnect', 'ack-timeout', 'invalid-json', 'wrong-session', 'schema-mismatch', 'drop', 'slow-reader')]
    [string]$Scenario = 'happy',

    [ValidateRange(0, 3600)]
    [int]$DurationSeconds = 0,

    [ValidateRange(0, 5000)]
    [int]$ReadDelayMs = 0,

    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.Encoding]::UTF8
$webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

function Read-ExactBytes {
    param(
        [System.IO.Stream]$Stream,
        [int]$Count
    )
    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'Client disconnected' }
        $offset += $read
    }
    return ,$buffer
}

function Read-HttpHeaders {
    param([System.IO.Stream]$Stream)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($bytes.Count -lt 8192) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'Client disconnected during handshake' }
        $bytes.Add([byte]$value)
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
            if ($Message.pairingToken -notmatch '^[0-9]{6}$') { $errors.Add('hello.pairingToken must be six digits') }
        }
        'hand_frame' {
            if ($Message.sessionId -ne $ActiveSession) { $errors.Add('hand_frame.sessionId does not match') }
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
    $invalidItems = ($rows | Measure-Object -Property invalidItems -Sum).Sum
    $bytes = ($rows | Measure-Object -Property receivedBytes -Sum).Sum
    @(
        '# YubiBoard mock server summary'
        ''
        "- Scenario: $Scenario"
        "- Connections: $($rows.Count)"
        "- Hand frames: $handFrames"
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
$script:eventLog = Join-Path $OutputDirectory 'events.jsonl'
$summaryFile = Join-Path $OutputDirectory 'connections.csv'
$runStartedAt = [DateTime]::UtcNow
$effectiveReadDelayMs = if ($Scenario -eq 'slow-reader' -and $ReadDelayMs -eq 0) { 500 } else { $ReadDelayMs }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "YubiBoard mock WebSocket server: 0.0.0.0:$Port/ws/v1/input"
Write-Host "Pairing token: $PairingToken / initial mode: $InitialMode / scenario: $Scenario"
Write-Host "Results: $OutputDirectory"
Write-Host 'Stop with Ctrl+C.'
Write-DebugEvent -Name 'server_started' -Data @{ port = $Port; scenario = $Scenario; initialMode = $InitialMode }

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $remote = $client.Client.RemoteEndPoint
        $sessionId = $null
        $connectionStartedAt = $null
        $frameCount = 0
        $missingCount = 0
        $markerCount = 0
        $heartbeatCount = 0
        $invalidCount = 0
        $gapCount = 0
        $bytesReceived = 0L
        Write-Host "Client connected: $remote"
        try {
            $stream = $client.GetStream()
            Complete-WebSocketHandshake -Stream $stream
            $sessionId = 'session-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $frameCount = 0
            $missingCount = 0
            $markerCount = 0
            $heartbeatCount = 0
            $invalidCount = 0
            $gapCount = 0
            $bytesReceived = 0L
            $lastFrameId = $null
            $connectionStartedAt = [DateTime]::UtcNow
            $scenarioActionSent = $false
            Write-DebugEvent -Name 'client_connected' -Data @{ remote = $remote.ToString(); sessionId = $sessionId }
            while ($client.Connected) {
                if ($DurationSeconds -gt 0 -and ([DateTime]::UtcNow - $runStartedAt).TotalSeconds -ge $DurationSeconds) {
                    Send-WebSocketFrame -Stream $stream -Opcode 8 -Payload $utf8.GetBytes('duration complete')
                    break
                }
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
                }
                Write-DebugEvent -Name 'message_received' -Data @{ messageType = $message.messageType; bytes = $frame.Payload.Length; frameId = $message.frameId }
                switch ($message.messageType) {
                    'hello' {
                        if ($message.pairingToken -ne $PairingToken) {
                            Write-Warning "Rejected pairing token from $remote"
                            throw 'Pairing token did not match'
                        }
                        if ($Scenario -eq 'ack-timeout') {
                            Write-Host 'Scenario ack-timeout: hello_ack suppressed'
                            continue
                        }
                        $ackSchemaVersion = if ($Scenario -eq 'schema-mismatch') { 99 } else { 1 }
                        $ack = [ordered]@{
                            schemaVersion = $ackSchemaVersion
                            messageType = 'hello_ack'
                            sessionId = $sessionId
                            surface = [ordered]@{ surfaceId = 'mock-display'; widthPx = 1920; heightPx = 1080 }
                            calibrationRequired = $InitialMode -eq 'calibration'
                        } | ConvertTo-Json -Compress
                        Send-WebSocketText -Stream $stream -Text $ack
                        Write-Host "Handshake accepted: $sessionId"
                        Write-DebugEvent -Name 'hello_ack_sent' -Data @{ sessionId = $sessionId; schemaVersion = $ackSchemaVersion }
                        if ($Scenario -eq 'invalid-json') {
                            Send-WebSocketText -Stream $stream -Text '{not-valid-json'
                        } elseif ($Scenario -eq 'wrong-session') {
                            $control = [ordered]@{ schemaVersion = 1; messageType = 'control_message'; sessionId = 'wrong-session'; command = 'set_mode'; mode = 'calibration' } | ConvertTo-Json -Compress
                            Send-WebSocketText -Stream $stream -Text $control
                        }
                    }
                    'hand_frame' {
                        $frameCount++
                        if (-not $message.hand.detected) { $missingCount++ }
                        if ($null -ne $lastFrameId -and [long]$message.frameId -gt [long]$lastFrameId + 1) {
                            $gapCount += [long]$message.frameId - [long]$lastFrameId - 1
                        }
                        $lastFrameId = [long]$message.frameId
                        if ($frameCount -eq 1 -or $frameCount % 20 -eq 0) {
                            Write-Host "hand_frame #$($message.frameId): detected=$($message.hand.detected), received=$frameCount"
                        }
                    }
                    'calibration_markers' {
                        $markerCount++
                        Write-Host "calibration_markers: $($message.markers.Count)/4"
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
        } catch {
            Write-Warning $_.Exception.Message
            Write-DebugEvent -Name 'client_error' -Data @{ remote = $remote.ToString(); error = $_.Exception.Message }
        } finally {
            if ($null -ne $connectionStartedAt) {
                $duration = [Math]::Max(0.001, ([DateTime]::UtcNow - $connectionStartedAt).TotalSeconds)
                [pscustomobject]@{
                    startedAtUtc = $connectionStartedAt.ToString('o')
                    remote = $remote.ToString()
                    sessionId = $sessionId
                    durationSeconds = [Math]::Round($duration, 3)
                    handFrames = $frameCount
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
}
