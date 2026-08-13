param(
    [string]$Uri = 'ws://127.0.0.1:8080/ws/v1/input',
    [ValidatePattern('^[0-9]{6}$')]
    [string]$PairingToken = '123456',
    [ValidateRange(1, 120)]
    [int]$TwoHandFrames = 12
)

$ErrorActionPreference = 'Stop'

function Receive-WebSocketJson {
    param([System.Net.WebSockets.ClientWebSocket]$Socket)
    $buffer = [byte[]]::new(16KB)
    $stream = [System.IO.MemoryStream]::new()
    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $result = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $stream.Write($buffer, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
}

function Send-WebSocketJson {
    param([System.Net.WebSockets.ClientWebSocket]$Socket, [object]$Value)
    $json = $Value | ConvertTo-Json -Compress -Depth 12
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()
}

function New-Hand {
    param([int]$TrackId, [double]$BaseX, [string]$Handedness)
    $landmarks = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 21; $index++) {
        [void]$landmarks.Add(@(
            [Math]::Round($BaseX + ($index % 5) * 0.04, 4),
            [Math]::Round(0.22 + [Math]::Floor($index / 5) * 0.11, 4),
            [Math]::Round(-0.001 * $index, 4)
        ))
    }
    return [ordered]@{
        trackId = $TrackId
        handedness = $Handedness
        handednessScore = 0.98
        coordinateSpace = 'normalized_camera'
        landmarkFormat = 'mediapipe_hand_21'
        landmarks = @($landmarks)
    }
}

function New-HandFrame {
    param([string]$SessionId, [long]$FrameId, [object[]]$Hands)
    $legacy = if ($Hands.Count -eq 0) {
        [ordered]@{ detected = $false }
    } else {
        $primary = $Hands | Sort-Object { [int]$_.trackId } | Select-Object -First 1
        [ordered]@{
            detected = $true
            handedness = $primary.handedness
            handednessScore = $primary.handednessScore
            coordinateSpace = $primary.coordinateSpace
            landmarkFormat = $primary.landmarkFormat
            landmarks = $primary.landmarks
        }
    }
    return [ordered]@{
        schemaVersion = 1
        messageType = 'hand_frame'
        sessionId = $SessionId
        frameId = $FrameId
        capturedAtMonotonicMs = 10000 + $FrameId * 50
        source = [ordered]@{
            width = 960; height = 540; rotationDegrees = 0
            rotationCorrected = $true; mirrorCorrected = $true
        }
        hands = @($Hands)
        hand = $legacy
    }
}

$socket = [System.Net.WebSockets.ClientWebSocket]::new()
try {
    [void]$socket.ConnectAsync([Uri]$Uri, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    Send-WebSocketJson -Socket $socket -Value ([ordered]@{
        schemaVersion = 1
        messageType = 'hello'
        deviceId = 'mock-two-hand-android'
        client = 'yubiboard-android'
        clientVersion = '0.1.0'
        pairingToken = $PairingToken
        interactionProfile = 'two_users_two_active_hands'
        maxHands = 2
        coordinateSpace = 'normalized_camera'
        capabilities = @(
            'aruco_calibration', 'hand_landmarks_21', 'multi_hand_landmarks_21',
            'stable_hand_track_id', 'calibration_status', 'hello_error', 'trusted_reconnect'
        )
    })
    $ack = Receive-WebSocketJson -Socket $socket
    if ($ack.messageType -ne 'hello_ack' -or
        $ack.acceptedInteractionProfile -ne 'two_users_two_active_hands') {
        throw "Mock server did not accept the two-hand profile: $($ack | ConvertTo-Json -Compress)"
    }
    $left = New-Hand -TrackId 7 -BaseX 0.15 -Handedness LEFT
    $right = New-Hand -TrackId 12 -BaseX 0.65 -Handedness RIGHT
    $frameId = 1L
    for ($index = 0; $index -lt $TwoHandFrames; $index++) {
        Send-WebSocketJson -Socket $socket -Value (
            New-HandFrame -SessionId $ack.sessionId -FrameId $frameId -Hands @($left, $right)
        )
        $frameId++
        Start-Sleep -Milliseconds 50
    }
    Send-WebSocketJson -Socket $socket -Value (
        New-HandFrame -SessionId $ack.sessionId -FrameId $frameId -Hands @($left)
    )
    $frameId++
    Send-WebSocketJson -Socket $socket -Value (
        New-HandFrame -SessionId $ack.sessionId -FrameId $frameId -Hands @()
    )
    [void]$socket.CloseAsync(
        [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
        'mock complete',
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult()
    Write-Host "Sent $TwoHandFrames two-hand frames plus one-hand and zero-hand frames."
} finally {
    $socket.Dispose()
}
