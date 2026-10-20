# dong-goi.ps1 — đóng gói Kho-session-Claude.zip để gửi người khác
# Chạy: powershell -NoProfile -ExecutionPolicy Bypass -File dong-goi.ps1
# Tự viết từng mục zip (dấu "/", tên UTF-8): ZipFile.CreateFromDirectory của PowerShell 5.1
# ghi đường dẫn bằng "\" — sai chuẩn zip, công cụ khác giải nén ra tên hỏng.
# LƯU Ý: file này phải lưu UTF-8 CÓ BOM (có tên file tiếng Việt).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$dir = $PSScriptRoot
$files = @('Kho session Claude.bat', 'cs-gui.ps1', 'ui.html', 'HƯỚNG DẪN.txt')
$out = Join-Path $dir 'Kho-session-Claude.zip'
$tmp = $out + '.cs-tmp'

$fs = [IO.File]::Open($tmp, [IO.FileMode]::Create)
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
try {
  foreach ($f in $files) {
    $src = Join-Path $dir $f
    if (-not [IO.File]::Exists($src)) { throw ('Thieu file: ' + $f) }
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $src, 'Kho session Claude/' + $f, [IO.Compression.CompressionLevel]::Optimal)
  }
} finally { $zip.Dispose(); $fs.Dispose() }
Move-Item -LiteralPath $tmp -Destination $out -Force
'Da dong goi: ' + $out
