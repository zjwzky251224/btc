$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceFiles = @()
foreach ($folder in @('contracts', 'scripts', 'test')) {
    $sourceFiles += Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -File -Recurse |
        Where-Object { $_.Extension -in @('.sol', '.mjs', '.ps1') }
}
foreach ($file in @('package.json', 'package-lock.json', 'LICENSE', '.gitignore', '.nvmrc', 'config/testnet.example.json')) {
    $sourceFiles += Get-Item -LiteralPath (Join-Path $projectRoot $file)
}
# Explicit source whitelist: never package reports, environment files, artifacts or installed dependencies.
Add-Type -AssemblyName System.IO.Compression
$outputPath = Join-Path $projectRoot 'omnichain-lending-code.zip'
$stream = [System.IO.File]::Open($outputPath, [System.IO.FileMode]::Create)
try {
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($file in ($sourceFiles | Sort-Object FullName)) {
            $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
            if (-not $fullPath.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'Source path is outside the project or a link' }
            $relative = $fullPath.Substring($projectRoot.Length + 1).Replace('\', '/')
            $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $inputStream = [System.IO.File]::OpenRead($fullPath)
            $entryStream = $entry.Open()
            try { $inputStream.CopyTo($entryStream) } finally { $inputStream.Dispose(); $entryStream.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }
Write-Output "Source archive: $outputPath ($($sourceFiles.Count) files)"
