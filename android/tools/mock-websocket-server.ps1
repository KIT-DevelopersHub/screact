param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidatePattern('^[0-9]{6}$')]
    [string]$PairingToken = '123456',

    [ValidateSet('tracking', 'calibration')]
    [string]$InitialMode = 'tracking'
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
        $length = ($extended[0] -shl 8) -bor $extended[1]
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

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "YubiBoard mock WebSocket server: 0.0.0.0:$Port/ws/v1/input"
Write-Host "Pairing token: $PairingToken / initial mode: $InitialMode"
Write-Host 'Stop with Ctrl+C.'

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $remote = $client.Client.RemoteEndPoint
        Write-Host "Client connected: $remote"
        try {
            $stream = $client.GetStream()
            Complete-WebSocketHandshake -Stream $stream
            $sessionId = 'session-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $frameCount = 0
            while ($client.Connected) {
                $frame = Read-WebSocketFrame -Stream $stream
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
                $message = $text | ConvertFrom-Json
                switch ($message.messageType) {
                    'hello' {
                        if ($message.pairingToken -ne $PairingToken) {
                            Write-Warning "Rejected pairing token from $remote"
                            throw 'Pairing token did not match'
                        }
                        $ack = [ordered]@{
                            schemaVersion = 1
                            messageType = 'hello_ack'
                            sessionId = $sessionId
                            surface = [ordered]@{ surfaceId = 'mock-display'; widthPx = 1920; heightPx = 1080 }
                            calibrationRequired = $InitialMode -eq 'calibration'
                        } | ConvertTo-Json -Compress
                        Send-WebSocketText -Stream $stream -Text $ack
                        Write-Host "Handshake accepted: $sessionId"
                    }
                    'hand_frame' {
                        $frameCount++
                        if ($frameCount -eq 1 -or $frameCount % 20 -eq 0) {
                            Write-Host "hand_frame #$($message.frameId): detected=$($message.hand.detected), received=$frameCount"
                        }
                    }
                    'calibration_markers' {
                        Write-Host "calibration_markers: $($message.markers.Count)/4"
                    }
                    'heartbeat' {
                        Write-Verbose "heartbeat: $($message.sentAtMonotonicMs)"
                    }
                    default {
                        Write-Warning "Unknown message type: $($message.messageType)"
                    }
                }
            }
        } catch {
            Write-Warning $_.Exception.Message
        } finally {
            $client.Dispose()
            Write-Host "Client disconnected: $remote"
        }
    }
} finally {
    $listener.Stop()
}
