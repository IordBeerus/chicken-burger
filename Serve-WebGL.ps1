param(
    [string]$Root = $PSScriptRoot,
    [int]$Port = 8090
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
$rootPrefix = $Root + [IO.Path]::DirectorySeparatorChar
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
$url = "http://127.0.0.1:$Port/"
Write-Host "Serving Unity WebGL from $Root at $url. Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $fileStream = $null
        $responseBody = [byte[]]::Empty
        $contentLength = 0L
        $headersSent = $false
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            while ($reader.ReadLine() -ne '') { }
            $requestParts = $requestLine.Split(' ')
            $method = $requestParts[0]
            $requestPath = $requestParts[1].Split('?')[0]
            $relative = [Uri]::UnescapeDataString($requestPath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative -eq '/') { $relative = 'index.html' }
            $candidate = [IO.Path]::GetFullPath((Join-Path $Root $relative.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)))
            $isInsideRoot = $candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
            if (-not $isInsideRoot -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $status = '404 Not Found'; $responseBody = [Text.Encoding]::UTF8.GetBytes('Not Found'); $contentLength = $responseBody.Length; $type = 'text/plain'; $encoding = ''
            } else {
                $status = '200 OK'
                $fileStream = [IO.File]::Open($candidate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                $contentLength = $fileStream.Length
                $encoding = ''
                $type = switch -Regex ($candidate) {
                    '\.wasm(\.br)?$' { 'application/wasm'; break }
                    '\.(framework\.js|js)(\.br)?$' { 'application/javascript'; break }
                    '\.data(\.br)?$' { 'application/octet-stream'; break }
                    '\.html$' { 'text/html; charset=utf-8'; break }
                    '\.css$' { 'text/css'; break }
                    '\.png$' { 'image/png'; break }
                    '\.jpe?g$' { 'image/jpeg'; break }
                    '\.ico$' { 'image/x-icon'; break }
                    default { 'application/octet-stream' }
                }
                if ($candidate.EndsWith('.br', [StringComparison]::OrdinalIgnoreCase)) { $encoding = "`r`nContent-Encoding: br" }
            }
            $headOnly = $method -eq 'HEAD'
            $header = "HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $contentLength`r`nCache-Control: no-cache$encoding`r`nConnection: close`r`n`r`n"
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $headersSent = $true
            if (-not $headOnly) {
                if ($fileStream) {
                    $fileStream.CopyTo($stream, 65536)
                } elseif ($responseBody.Length -gt 0) {
                    $stream.Write($responseBody, 0, $responseBody.Length)
                }
            }
        } catch {
            Write-Warning $_
            if (-not $headersSent) {
                $errorBody = [Text.Encoding]::UTF8.GetBytes('Internal Server Error')
                $errorHeader = "HTTP/1.1 500 Internal Server Error`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($errorBody.Length)`r`nConnection: close`r`n`r`n"
                try {
                    $errorHeaderBytes = [Text.Encoding]::ASCII.GetBytes($errorHeader)
                    $stream.Write($errorHeaderBytes, 0, $errorHeaderBytes.Length)
                    $stream.Write($errorBody, 0, $errorBody.Length)
                } catch {
                    Write-Warning $_
                }
            }
        } finally {
            if ($fileStream) { $fileStream.Dispose() }
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
