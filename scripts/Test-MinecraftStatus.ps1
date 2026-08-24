#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $HostName = 'mc.negativezone.cc',
    [int] $Port = 25565,
    [string] $ExpectedVersion,
    [int] $Attempts = 1,
    [int] $DelaySeconds = 20
)

$ErrorActionPreference = 'Stop'

function ConvertTo-VarInt([int] $Value) {
    $bytes = [Collections.Generic.List[byte]]::new()
    do {
        $part = $Value -band 0x7f
        $Value = $Value -shr 7
        if ($Value -ne 0) { $part = $part -bor 0x80 }
        $bytes.Add([byte]$part)
    } while ($Value -ne 0)
    return $bytes.ToArray()
}

function Read-VarInt([IO.Stream] $Stream) {
    $value = 0
    $position = 0
    do {
        $read = $Stream.ReadByte()
        if ($read -lt 0) { throw 'Unexpected EOF while reading VarInt.' }
        $value = $value -bor (($read -band 0x7f) -shl $position)
        $position += 7
        if ($position -gt 35) { throw 'Minecraft VarInt is too large.' }
    } while (($read -band 0x80) -ne 0)
    return $value
}

function Write-VarInt([IO.Stream] $Stream, [int] $Value) {
    $bytes = ConvertTo-VarInt $Value
    $Stream.Write($bytes, 0, $bytes.Length)
}

function Get-DescriptionText($Description) {
    if ($null -eq $Description) { return '' }
    if ($Description -is [string]) { return $Description }
    $parts = [Collections.Generic.List[string]]::new()
    if ($Description.text) { $parts.Add([string]$Description.text) }
    foreach ($extra in @($Description.extra)) {
        $text = Get-DescriptionText $extra
        if ($text) { $parts.Add($text) }
    }
    return ($parts -join '')
}

function Invoke-MinecraftStatus {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync($HostName, $Port)
        if (-not $connect.Wait([TimeSpan]::FromSeconds(10))) {
            throw 'TCP connect timed out.'
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $stream.WriteTimeout = 10000

        $hostBytes = [Text.Encoding]::UTF8.GetBytes($HostName)
        $payload = [IO.MemoryStream]::new()
        try {
            Write-VarInt $payload 0
            Write-VarInt $payload 763
            Write-VarInt $payload $hostBytes.Length
            $payload.Write($hostBytes, 0, $hostBytes.Length)
            $payload.WriteByte([byte](($Port -shr 8) -band 0xff))
            $payload.WriteByte([byte]($Port -band 0xff))
            Write-VarInt $payload 1
            Write-VarInt $stream ([int]$payload.Length)
            $payload.Position = 0
            $payload.CopyTo($stream)
        } finally {
            $payload.Dispose()
        }
        $stream.WriteByte(1)
        $stream.WriteByte(0)
        $stream.Flush()

        [void](Read-VarInt $stream)
        if ((Read-VarInt $stream) -ne 0) { throw 'Unexpected status response packet.' }
        $jsonLength = Read-VarInt $stream
        $jsonBytes = [byte[]]::new($jsonLength)
        $offset = 0
        while ($offset -lt $jsonLength) {
            $read = $stream.Read($jsonBytes, $offset, $jsonLength - $offset)
            if ($read -le 0) { throw 'Unexpected EOF in status response.' }
            $offset += $read
        }
        return [Text.Encoding]::UTF8.GetString($jsonBytes) | ConvertFrom-Json
    } finally {
        $client.Dispose()
    }
}

$lastError = $null
for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
        $status = Invoke-MinecraftStatus
        $description = Get-DescriptionText $status.description
        if ($ExpectedVersion -and $description -notmatch [regex]::Escape("v$ExpectedVersion")) {
            throw "MOTD '$description' does not advertise v$ExpectedVersion."
        }
        Write-Host "Minecraft status healthy: $description"
        exit 0
    } catch {
        $lastError = $_
        Write-Warning "Minecraft status attempt $attempt/$Attempts failed: $($_.Exception.Message)"
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
}

throw "Minecraft status gate failed after $Attempts attempt(s): $($lastError.Exception.Message)"
