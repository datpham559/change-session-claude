# cs-gui.ps1 — Kho session Claude (PowerShell 5.1 có sẵn trong Windows, không cần cài gì)
# Chạy: powershell -NoProfile -ExecutionPolicy Bypass -File cs-gui.ps1
#   -> tự mở trình duyệt tại http://127.0.0.1:4777. Giao diện nằm ở ui.html.
# LƯU Ý: file này phải lưu UTF-8 CÓ BOM, nếu không PowerShell 5.1 đọc sai tiếng Việt.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions

$Utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8 } catch {}
$Js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Js.MaxJsonLength = [int]::MaxValue
$Js.RecursionLimit = 1000
$Inv = [Globalization.CultureInfo]::InvariantCulture

$UserHome = $env:USERPROFILE
$CfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserHome '.claude' }
$Root = Join-Path $CfgDir 'projects'
$AccountFile = Join-Path $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $UserHome }) '.claude.json'
$Port = if ($env:CS_PORT) { [int]$env:CS_PORT } else { 4777 }
$TokenBytes = New-Object byte[] 16
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($TokenBytes)
$Token = -join ($TokenBytes | ForEach-Object { $_.ToString('x2') })
$UiFile = Join-Path $PSScriptRoot 'ui.html'
$BackupDir = Join-Path $UserHome '.claude\cs-backups'
$AccountsFile = Join-Path $UserHome '.claude\cs-accounts.txt'

$UuidPat = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$UuidRe = '^' + $UuidPat + '$'
$IdRe = '^[A-Za-z0-9-]+$'
# Phiên được mở từ tool cũ ghi mã session cũ trong tin nhắn đầu -> nhận ra là "phần tiếp theo"
$ParentRe = '(?:Nối tiếp session: |File lịch sử đầy đủ: .*?)(' + $UuidPat + ')'
$HandoffRe = '^Tiếp tục công việc từ một session'
$RELOAD_MSG = 'Bấm “Khởi động lại Claude Desktop” để thấy thay đổi (nhanh, tự động).'

# ================= tiện ích =================
# Dấu phẩy trước giá trị trả về: giữ nguyên mảng (PowerShell tự "bóc" mảng 1 phần tử khi return)
function Get-Key($o, [string]$k) {
  if ($o -is [System.Collections.IDictionary]) { return ,$o[$k] } # khoá không có -> $null
  return $null
}
function Parse-Json([string]$s) { try { return ,$Js.DeserializeObject($s) } catch { return $null } }
function To-Num($v) { if ($null -eq $v) { return 0 }; try { return [double]$v } catch { return 0 } }
function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Leaf([string]$p) { return [IO.Path]::GetFileName($p.TrimEnd('\', '/')) }
function Test-PathRaw([string]$p) { return [bool]($p -and ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p))) }
# Thư mục dữ liệu (userData) có thể có của Claude Desktop — tuỳ cách cài và phiên bản app:
# - %LOCALAPPDATA%\Claude-Data\<gói>: bản Store mới trên Windows 11 tự CHUYỂN dữ liệu ra khỏi gói
#   (bật theo đợt; mã app 2.42304 + AppxManifest). Chỗ cũ trong gói mất luôn -> tool cũ báo "Không
#   tìm thấy dữ liệu của Claude Desktop" (người dùng báo 20/10/2026).
# - %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude: bản Store chưa chuyển.
# - %APPDATA%\Claude: bản cài bằng file .exe. - %LOCALAPPDATA%\Claude-3p: chế độ nhà cung cấp 3P.
# - CLAUDE_USER_DATA_DIR: chỉ bản dev dùng (bản phát hành bỏ qua biến này) — giữ cho đủ.
$script:DataDirsCache = $null
function Desktop-DataDirs {
  $now = Now-Ms
  if ($script:DataDirsCache -and $now - $script:DataDirsCache.at -lt 5000) { return ,$script:DataDirsCache.dirs }
  $c = New-Object System.Collections.Generic.List[string]
  if ($env:CLAUDE_USER_DATA_DIR) { $c.Add($env:CLAUDE_USER_DATA_DIR) }
  $la = $env:LOCALAPPDATA
  if ($la) {
    $moved = Join-Path $la 'Claude-Data'
    if ([IO.Directory]::Exists($moved)) { foreach ($d in [IO.Directory]::GetDirectories($moved)) { $c.Add($d) } }
    $pk = Join-Path $la 'Packages'
    if ([IO.Directory]::Exists($pk)) { foreach ($d in [IO.Directory]::GetDirectories($pk, 'Claude_*')) { $c.Add((Join-Path $d 'LocalCache\Roaming\Claude')) } }
  }
  if ($env:APPDATA) { $c.Add((Join-Path $env:APPDATA 'Claude')) }
  if ($la) { $c.Add((Join-Path $la 'Claude-3p')) }
  $script:DataDirsCache = @{ at = $now; dirs = $c }
  return ,$c
}
# Claude Desktop bản Microsoft Store chạy trong vùng ảo hoá của Windows: nó ghi vào file chat đường
# dẫn "ảo" %APPDATA%\Claude\... (vd thư mục scratch-workspaces), nhưng thật ra thư mục nằm trong
# thư mục dữ liệu thật của app (ở trên). Tool chạy NGOÀI vùng đó nên phải tự đổi sang đường dẫn
# thật, không thì báo nhầm "thư mục không còn tồn tại" (đã dính 16/10/2026).
$AppDataClaude = (Join-Path $env:APPDATA 'Claude').TrimEnd('\') + '\'
function Path-Exists([string]$p) {
  if (Test-PathRaw $p) { return $true }
  if (-not $p -or -not $p.StartsWith($AppDataClaude, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  $rest = $p.Substring($AppDataClaude.Length)
  foreach ($d in (Desktop-DataDirs)) { if (Test-PathRaw (Join-Path $d $rest)) { return $true } }
  return $false
}

# .NET Framework của PowerShell 5.1 giới hạn đường dẫn 260 ký tự (tên người dùng dài là vượt);
# tiền tố \\?\ gỡ giới hạn đó.
# ĐẶT TÊN HÀM CẨN THẬN: bí danh có sẵn được ưu tiên hơn hàm (vd "lp" = Out-Printer).
function Long-Path([string]$p) { if ($p.Length -ge 240 -and -not $p.StartsWith('\\?\')) { return '\\?\' + $p }; return $p }

# Đọc file kể cả khi Claude đang ghi vào nó (chia sẻ ReadWrite/Delete)
function Open-Shared([string]$file) {
  return New-Object IO.FileStream((Long-Path $file), [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
}
function Read-Slice([string]$file, [long]$start, [long]$len) {
  $fs = Open-Shared $file
  try {
    $buf = New-Object byte[] $len
    [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
    $n = 0
    while ($n -lt $len) { $r = $fs.Read($buf, $n, $len - $n); if ($r -le 0) { break }; $n += $r }
    return $Utf8.GetString($buf, 0, $n)
  } finally { $fs.Dispose() }
}
function Read-AllText([string]$file) {
  $fs = Open-Shared $file
  try { $sr = New-Object IO.StreamReader($fs, $Utf8); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}
# Ghi kiểu nguyên tử: ghi .cs-tmp rồi thay thế; UTF-8 KHÔNG BOM (thẻ có BOM thì app bỏ qua)
function Write-Atomic([string]$dest, [string]$content) {
  $tmp = Long-Path ($dest + '.cs-tmp'); $d = Long-Path $dest
  [IO.File]::WriteAllText($tmp, $content, $Utf8)
  if (-not [IO.File]::Exists($d)) { [IO.File]::Move($tmp, $d); return }
  # [NullString]::Value chứ không phải $null: PowerShell đổi $null thành "" khi gọi hàm .NET
  try {
    if ($d.StartsWith('\\?\')) { [IO.File]::Copy($tmp, $d, $true); [IO.File]::Delete($tmp) } # Replace không nhận \\?\
    else { [IO.File]::Replace($tmp, $d, [NullString]::Value) }
  } catch { try { [IO.File]::Delete($tmp) } catch {}; throw }
}

# JSON cho phản hồi API (hàm riêng: bộ JSON của .NET không xử lý được đối tượng PowerShell)
function Write-JsonValue($sb, $v) {
  if ($null -eq $v) { [void]$sb.Append('null'); return }
  if ($v -is [string] -or $v -is [char]) { [void]$sb.Append($Js.Serialize([string]$v)); return }
  if ($v -is [bool]) { [void]$sb.Append($(if ($v) { 'true' } else { 'false' })); return }
  if ($v -is [System.Collections.IDictionary]) {
    [void]$sb.Append('{'); $first = $true
    foreach ($k in @($v.Keys)) {
      if (-not $first) { [void]$sb.Append(',') }; $first = $false
      [void]$sb.Append($Js.Serialize([string]$k)); [void]$sb.Append(':'); Write-JsonValue $sb $v[$k]
    }
    [void]$sb.Append('}'); return
  }
  if ($v -is [System.Collections.IEnumerable]) {
    [void]$sb.Append('['); $first = $true
    foreach ($x in $v) { if (-not $first) { [void]$sb.Append(',') }; $first = $false; Write-JsonValue $sb $x }
    [void]$sb.Append(']'); return
  }
  if ($v -is [double] -or $v -is [single]) { [void]$sb.Append($v.ToString('R', $Inv)); return }
  if ($v -is [ValueType]) { [void]$sb.Append(([IFormattable]$v).ToString($null, $Inv)); return }
  [void]$sb.Append($Js.Serialize([string]$v))
}
function To-JsonText($v) { $sb = New-Object System.Text.StringBuilder; Write-JsonValue $sb $v; return $sb.ToString() }

# ================= đọc session =================
function Text-Of($content) {
  if ($content -is [string]) { return $content }
  if ($content -is [System.Collections.IEnumerable]) {
    $parts = @(foreach ($b in $content) { if ((Get-Key $b 'type') -eq 'text') { [string](Get-Key $b 'text') } })
    return ($parts -join "`n")
  }
  return ''
}
function Is-Noise([string]$t) {
  return (-not $t) -or ($t -cmatch '^\s*<(command-|local-command|system-reminder)') -or $t.StartsWith('Caveat:')
}

# ---- cache kết quả quét, lưu ra đĩa để lần mở tool sau không phải quét lại ----
# file chat -> @{ mtime; size; data }. Chỉ file nào đổi (mtime/kích thước) mới quét lại.
$CacheFile = Join-Path $UserHome '.claude\cs-cache.json'
$CacheVersion = 1 # tăng khi đổi cách tính dữ liệu trong Parse-Session -> cache cũ bị bỏ
$script:Cache = @{}
$script:CacheDirty = $false

function Load-SessionCache {
  try {
    if (-not [IO.File]::Exists($CacheFile)) { return }
    $o = Parse-Json (Read-AllText $CacheFile)
    if ((Get-Key $o 'version') -ne $CacheVersion) { return }
    $entries = Get-Key $o 'entries'
    foreach ($k in @($entries.Keys)) {
      $e = $entries[$k]; $d = Get-Key $e 'data'
      $data = @{}; foreach ($dk in @($d.Keys)) { $data[$dk] = $d[$dk] }
      $script:Cache[$k] = @{ mtime = [long](Get-Key $e 'mtime'); size = [long](Get-Key $e 'size'); data = $data }
    }
  } catch { $script:Cache = @{} }
}
function Save-SessionCache($files) {
  if (-not $script:CacheDirty) { return }
  try {
    $entries = [ordered]@{}
    foreach ($f in $files) { if ($script:Cache.ContainsKey($f)) { $entries[$f] = $script:Cache[$f] } } # bỏ file đã mất
    [void][IO.Directory]::CreateDirectory((Split-Path $CacheFile))
    Write-Atomic $CacheFile (To-JsonText ([ordered]@{ version = $CacheVersion; entries = $entries }))
    $script:CacheDirty = $false
  } catch {}
}

function Parse-Session([string]$file) {
  $fi = New-Object IO.FileInfo((Long-Path $file))
  $mtime = [DateTimeOffset]::new($fi.LastWriteTimeUtc).ToUnixTimeMilliseconds()
  $hit = $script:Cache[$file]
  if ($hit -and $hit.mtime -eq $mtime -and $hit.size -eq $fi.Length) {
    $hit.data.exists = $(if ($hit.data.cwd) { Path-Exists $hit.data.cwd } else { $false }) # thư mục có thể vừa bị xoá
    return $hit.data
  }
  $Ord = [StringComparison]::Ordinal

  # Đầu file: thư mục làm việc, nhánh git, tin nhắn đầu tiên của người dùng. Chỉ parse JSON
  # những dòng còn có thể cho thông tin chưa có (dòng trả lời dài của Claude thì bỏ qua).
  $cwd = $null; $title = $null; $branch = $null
  $head = Read-Slice $file 0 ([Math]::Min($fi.Length, 512KB))
  foreach ($line in $head.Split("`n")) {
    $need = (-not $cwd -and $line.IndexOf('"cwd"', $Ord) -ge 0) -or
            (-not $branch -and $line.IndexOf('"gitBranch"', $Ord) -ge 0) -or
            (-not $title -and $line.IndexOf('"user"', $Ord) -ge 0)
    if (-not $need) { continue }
    $o = Parse-Json $line
    if ($null -eq $o) { continue }
    if (-not $cwd -and (Get-Key $o 'cwd')) { $cwd = [string](Get-Key $o 'cwd') }
    if (-not $branch -and (Get-Key $o 'gitBranch')) { $branch = [string](Get-Key $o 'gitBranch') }
    if (-not $title -and (Get-Key $o 'type') -eq 'user' -and -not (Get-Key $o 'isMeta') -and (Get-Key $o 'message')) {
      $t = ((Text-Of (Get-Key (Get-Key $o 'message') 'content')) -replace '\s+', ' ').Trim()
      if (-not (Is-Noise $t)) { $title = $t }
    }
    if ($cwd -and $title -and $branch) { break }
  }

  # Tiêu đề do app đặt (đổi tên / AI tự đặt) / tóm tắt được ghi thêm dọc file; bản MỚI NHẤT thắng.
  # Gom vị trí các dòng ứng viên (tìm chuỗi thường — regex chậm gấp chục lần trên file vài chục MB),
  # rồi duyệt NGƯỢC từ cuối: dòng đầu tiên gặp của mỗi loại chính là bản mới nhất, nên chỉ phải
  # parse vài dòng thay vì hàng trăm.
  $custom = $null; $auto = $null; $summary = $null
  try {
    $all = Read-AllText $file
    $len = $all.Length; $pos = 0; $na = -2; $nb = -2 # -2: cần tìm lại, -1: hết
    $spans = New-Object System.Collections.Generic.List[int[]]
    while ($pos -lt $len) {
      if ($na -ne -1 -and $na -lt $pos) { $na = $all.IndexOf('itle"', $pos, $Ord) }
      if ($nb -ne -1 -and $nb -lt $pos) { $nb = $all.IndexOf('"summary"', $pos, $Ord) }
      if ($na -lt 0 -and $nb -lt 0) { break }
      $i = if ($na -lt 0) { $nb } elseif ($nb -lt 0) { $na } else { [Math]::Min($na, $nb) }
      $s0 = $all.LastIndexOf([char]10, $i) + 1
      $e0 = $all.IndexOf([char]10, $i); if ($e0 -lt 0) { $e0 = $len }
      $pos = $e0 + 1
      if ($e0 - $s0 -le 4000) { $spans.Add([int[]]@($s0, $e0)) }
    }
    $doneC = $false; $doneA = $false; $doneS = $false
    for ($k = $spans.Count - 1; $k -ge 0 -and -not ($doneC -and $doneA -and $doneS); $k--) {
      $line = $all.Substring($spans[$k][0], $spans[$k][1] - $spans[$k][0])
      $mayC = -not $doneC -and $line.IndexOf('"customTitle"', $Ord) -ge 0
      $mayA = -not $doneA -and ($line.IndexOf('"aiTitle"', $Ord) -ge 0 -or $line.IndexOf('"title"', $Ord) -ge 0)
      $mayS = -not $doneS -and $line.IndexOf('"summary"', $Ord) -ge 0
      if (-not ($mayC -or $mayA -or $mayS)) { continue }
      $o = Parse-Json $line
      if ($null -eq $o) { continue }
      $ty = Get-Key $o 'type'; $tt = Get-Key $o 'title'
      if ($mayC -and (Get-Key $o 'customTitle')) { $custom = [string](Get-Key $o 'customTitle'); $doneC = $true }
      if ($mayA) {
        # trong cùng một dòng, "title" (dòng không phải user/assistant) được ưu tiên hơn "aiTitle"
        if ($tt -is [string] -and $tt -and $ty -and $ty -ne 'user' -and $ty -ne 'assistant') { $auto = $tt; $doneA = $true }
        elseif (Get-Key $o 'aiTitle') { $auto = [string](Get-Key $o 'aiTitle'); $doneA = $true }
      }
      if ($mayS -and $ty -eq 'summary' -and (Get-Key $o 'summary')) { $summary = [string](Get-Key $o 'summary'); $doneS = $true }
    }
  } catch {}

  $best = 'Không có tiêu đề'
  foreach ($c in @($custom, $auto, $summary, $title)) { if ($c) { $best = $c; break } }
  if ($best.Length -gt 200) { $best = $best.Substring(0, 200) }
  $parent = $null
  if ($title -and $title -match $ParentRe) { $parent = $Matches[1] }
  $data = @{
    id = [IO.Path]::GetFileNameWithoutExtension($file); file = $file; cwd = $cwd
    project = $(if ($cwd) { Leaf $cwd } else { $null }); branch = $branch; title = $best
    named = [bool]($custom -or $auto -or $summary); parent = $parent; mtime = $mtime
    mb = [Math]::Round($fi.Length / 1MB, 1, [MidpointRounding]::AwayFromZero)
    exists = $(if ($cwd) { Path-Exists $cwd } else { $false })
  }
  $script:Cache[$file] = @{ mtime = $mtime; size = $fi.Length; data = $data }
  $script:CacheDirty = $true
  return $data
}

$script:Index = [ordered]@{}

function Scan-Sessions {
  $out = New-Object System.Collections.Generic.List[object]
  $seen = New-Object System.Collections.Generic.List[string]
  if ([IO.Directory]::Exists($Root)) {
    foreach ($dir in [IO.Directory]::GetDirectories($Root)) {
      foreach ($f in [IO.Directory]::GetFiles($dir, '*.jsonl')) {
        $seen.Add($f)
        try { $out.Add((Parse-Session $f)) } catch {}
      }
    }
  }
  Save-SessionCache $seen
  # Cùng một mã session có thể có file ở nhiều thư mục project (vd bản ở thư mục chính và bản ở
  # .claude-worktrees-… / scratch-workspaces, cùng phần đầu lịch sử): gộp thành MỘT mục, file ghi
  # gần nhất là bản chính (cwd, tiêu đề, xem trước…). Không gộp thì danh sách có 2 dòng cùng mã
  # và Index/ghép chuỗi chỉ giữ bản xếp sau.
  $byId = @{}
  foreach ($s in $out) {
    if (-not $s.cwd) { continue }
    $cur = $byId[$s.id]
    if (-not $cur -or $s.mtime -gt $cur.mtime) { $byId[$s.id] = $s }
  }
  $list = @($out | Where-Object { $_.cwd -and [object]::ReferenceEquals($byId[$_.id], $_) })

  # Mỗi session cha chỉ nối với phần tiếp theo mới nhất của nó
  $nextOf = @{}
  foreach ($s in $list) {
    if (-not $s.parent -or $s.parent -eq $s.id -or -not $byId.ContainsKey($s.parent)) { continue }
    $cur = $nextOf[$s.parent]
    if (-not $cur -or $s.mtime -gt $cur.mtime) { $nextOf[$s.parent] = $s }
  }
  $chains = New-Object System.Collections.Generic.List[object]
  foreach ($root in $list) {
    if ($root.parent -and $byId.ContainsKey($root.parent) -and $nextOf[$root.parent] -and $nextOf[$root.parent].id -eq $root.id) { continue }
    $parts = New-Object System.Collections.Generic.List[object]; $parts.Add($root)
    $seen = @{ $root.id = $true }; $cur = $root
    while ($nextOf.ContainsKey($cur.id) -and -not $seen.ContainsKey($nextOf[$cur.id].id)) {
      $cur = $nextOf[$cur.id]; $seen[$cur.id] = $true; $parts.Add($cur)
    }
    $last = $parts[$parts.Count - 1]
    $chains.Add(@{
      id = $last.id; parts = $parts
      title = $(if ($last.named -or $parts.Count -eq 1) { $last.title } else { $root.title })
      cwd = $last.cwd; project = $last.project; branch = $last.branch
      mtime = $last.mtime; mb = $last.mb; exists = $last.exists; count = $parts.Count
    })
  }
  $sorted = @($chains | Sort-Object -Property @{ Expression = { $_.mtime }; Descending = $true })
  $script:Index = [ordered]@{}
  foreach ($c in $sorted) { $script:Index[$c.id] = $c }
  return ,$sorted
}

function Preview-Of($s, [int]$keep) {
  $size = (New-Object IO.FileInfo((Long-Path $s.file))).Length
  $start = [Math]::Max(0, $size - 600KB)
  $msgs = New-Object System.Collections.Generic.List[object]
  foreach ($line in (Read-Slice $s.file $start ($size - $start)).Split("`n")) {
    if (-not $line.Trim()) { continue }
    $o = Parse-Json $line
    if ($null -eq $o) { continue }
    if (-not (Get-Key $o 'message') -or (Get-Key $o 'isMeta')) { continue }
    $type = Get-Key $o 'type'
    if ($type -ne 'user' -and $type -ne 'assistant') { continue }
    $t = (Text-Of (Get-Key (Get-Key $o 'message') 'content')).Trim()
    if (Is-Noise $t) { continue }
    if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) + "`n…" }
    $msgs.Add([ordered]@{ role = $type; text = $t; ts = (Get-Key $o 'timestamp') })
  }
  $from = [Math]::Max(0, $msgs.Count - $keep)
  return ,@($msgs | Select-Object -Skip $from)
}

# Ghép tin nhắn của cả chuỗi (bỏ tin nhắn bàn giao do tool cũ tạo)
function Chain-Messages($c, [int]$maxParts, [int]$perPart) {
  $parts = @($c.parts | Select-Object -Last $maxParts)
  $out = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $parts.Count; $i++) {
    $p = $parts[$i]
    if ($i -gt 0 -or $c.parts.Count -gt $parts.Count) {
      $txt = if ($i -eq 0) { 'Các phần trước đã lược bớt' } else { 'Phiên tiếp nối, ' + [DateTimeOffset]::FromUnixTimeMilliseconds($p.mtime).LocalDateTime.ToString('HH:mm:ss d/M/yyyy', $Inv) }
      $out.Add([ordered]@{ role = 'divider'; text = $txt })
    }
    foreach ($m in (Preview-Of $p $perPart)) {
      if (-not ($m.role -eq 'user' -and $m.text -match $HandoffRe)) { $out.Add($m) }
    }
  }
  return ,$out
}

# ================= Claude Desktop =================
# App giữ một "thẻ" cho mỗi session tại claude-code-sessions\<tài khoản>\<org>\local_<mã>.json
# - Org ĐANG ĐĂNG NHẬP: app giữ danh sách trong bộ nhớ -> nhập bằng deep link
#   claude://resume?session=<cli> (app tự ghi thẻ, hiện ngay, KHÔNG cần restart).
# - Tài khoản/org khác: chép file thẻ; app đọc lại khi chuyển sang tài khoản đó.
# Mọi so khớp theo cliSessionId (cùng session có thể mang tên thẻ khác nhau).
function Desktop-Root {
  if ($env:CS_DESKTOP_DIR) { return $env:CS_DESKTOP_DIR }
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($d in (Desktop-DataDirs)) { $p = Join-Path $d 'claude-code-sessions'; if ([IO.Directory]::Exists($p)) { $found.Add($p) } }
  if ($found.Count -eq 0) { return $null }
  if ($found.Count -eq 1) { return $found[0] }
  # Nhiều chỗ cùng có (vd app đã chuyển ra Claude-Data mà gói vẫn còn hồ sơ cũ): app đang dùng chỗ
  # nào thì thẻ ở đó được ghi gần nhất (app ghi thẻ mỗi lần bấm/dùng session).
  $best = $found[0]; $bestT = [DateTime]::MinValue
  foreach ($r in $found) {
    $t = [DateTime]::MinValue
    try {
      foreach ($f in [IO.Directory]::EnumerateFiles('\\?\' + $r, 'local_*.json', [IO.SearchOption]::AllDirectories)) {
        $w = [IO.File]::GetLastWriteTimeUtc($f); if ($w -gt $t) { $t = $w }
      }
    } catch {}
    if ($t -gt $bestT) { $best = $r; $bestT = $t }
  }
  return $best
}
# Có Claude Desktop trên máy không (bản Store: có thư mục gói; bản .exe: có claude.exe)
function Desktop-Installed {
  if (Desktop-Exe) { return $true }
  $pk = Join-Path $env:LOCALAPPDATA 'Packages'
  if ([IO.Directory]::Exists($pk) -and [IO.Directory]::GetDirectories($pk, 'Claude_*').Count) { return $true }
  return [IO.File]::Exists((Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'))
}

# Tên tài khoản: C:\Users\<bạn>\.claude\cs-accounts.txt (mỗi dòng: <8 ký tự mã> = <tên>)
function Read-AccountNames {
  $map = @{}
  try {
    foreach ($line in [IO.File]::ReadAllLines($AccountsFile, $Utf8)) {
      if ($line -match '^\s*([0-9a-f]{8})\s*=\s*(.+?)\s*$') { $map[$Matches[1].ToLower()] = $Matches[2] }
    }
  } catch {}
  return $map
}
function Ensure-AccountsFile($ids) {
  try {
    if ([IO.File]::Exists($AccountsFile)) { return }
    [void][IO.Directory]::CreateDirectory((Split-Path $AccountsFile))
    $body = @('# Đặt tên cho từng tài khoản Claude Desktop.', '# Sửa phần sau dấu = rồi lưu, mở lại tool để thấy tên mới.', '') + @($ids | ForEach-Object { $_.Substring(0, 8) + ' = ' + $_.Substring(0, 8) })
    [IO.File]::WriteAllText($AccountsFile, ($body -join "`n") + "`n", $Utf8)
  } catch {}
}

$script:OAuthCache = $null
function Current-OAuth {
  $none = @{ email = $null; uuid = $null; org = $null }
  try {
    $fi = New-Object IO.FileInfo($AccountFile)
    if (-not $fi.Exists) { return $none }
    $stamp = $fi.LastWriteTimeUtc.Ticks
    if ($script:OAuthCache -and $script:OAuthCache.stamp -eq $stamp) { return $script:OAuthCache.value }
    $o = Get-Key (Parse-Json (Read-AllText $AccountFile)) 'oauthAccount'
    $v = @{ email = (Get-Key $o 'emailAddress'); uuid = (Get-Key $o 'accountUuid'); org = (Get-Key $o 'organizationUuid') }
    $script:OAuthCache = @{ stamp = $stamp; value = $v }
    return $v
  } catch { return $none }
}

# Tự học: ghi 'accountUuid(8) = email' cho tài khoản đang đăng nhập nếu dòng đó chưa có tên
function Learn-CurrentName {
  try {
    $cur = Current-OAuth
    if (-not $cur.email -or -not $cur.uuid) { return }
    $key = $cur.uuid.Substring(0, 8).ToLower()
    $names = Read-AccountNames
    if ($names[$key] -and $names[$key] -ne $key) { return }
    $local = $cur.email.Split('@')[0]
    $old = @()
    if ([IO.File]::Exists($AccountsFile)) { $old = @([IO.File]::ReadAllText($AccountsFile, $Utf8).Split("`n")) }
    $found = $false
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $old) {
      if ($l -match ('^\s*' + $key + '\s*=')) { $found = $true; $lines.Add($key + ' = ' + $local) } else { $lines.Add($l) }
    }
    if (-not $found) { $lines.Add($key + ' = ' + $local) }
    [void][IO.Directory]::CreateDirectory((Split-Path $AccountsFile))
    [IO.File]::WriteAllText($AccountsFile, (($lines -join "`n") -replace "`n+$", '') + "`n", $Utf8)
  } catch {}
}

# Đặt tên từ giao diện (app không lưu email ở chỗ tool đọc được, nên tài khoản chưa từng đăng nhập
# Claude Code CLI chỉ có mã — người dùng tự đặt tên)
function Set-AccountName([string]$acct, [string]$name) {
  $key = $acct.Substring(0, 8).ToLower()
  $old = @(); if ([IO.File]::Exists($AccountsFile)) { $old = @([IO.File]::ReadAllText($AccountsFile, $Utf8).TrimEnd("`r", "`n").Split("`n")) }
  $lines = New-Object System.Collections.Generic.List[string]; $found = $false
  foreach ($l in $old) { if ($l -match ('^\s*' + $key + '\s*=')) { if (-not $found) { $lines.Add($key + ' = ' + $name) }; $found = $true } else { $lines.Add($l) } }
  if (-not $found) { $lines.Add($key + ' = ' + $name) }
  [void][IO.Directory]::CreateDirectory((Split-Path $AccountsFile))
  [IO.File]::WriteAllText($AccountsFile, (($lines -join "`n") -replace "`n+$", '') + "`n", $Utf8)
}

# Tên tự học từ Claude Desktop: trang claude.ai trong app cache thông tin tài khoản (…"uuid"…<mã>…
# "email_address"…<email>) trong IndexedDB. IndexedDB đi theo hồ sơ đăng nhập (cs-profiles) nên mỗi
# hồ sơ có email của đúng tài khoản đó. Chỉ điền tên còn trống / còn là mã — không đè tên người dùng đặt.
$script:NameScanDone = @{}
function Find-EmailIn([string]$dir, [string]$acct) {
  $idb = Join-Path $dir 'IndexedDB'
  if (-not [IO.Directory]::Exists($idb)) { return $null }
  $Ord = [StringComparison]::Ordinal
  foreach ($f in [IO.Directory]::GetFiles($idb, '*', [IO.SearchOption]::AllDirectories)) {
    $fi = New-Object IO.FileInfo($f)
    if ($fi.Length -lt 64 -or $fi.Length -gt 20MB) { continue }
    $k = $f + '|' + $fi.LastWriteTimeUtc.Ticks + '|' + $acct
    if ($script:NameScanDone.ContainsKey($k)) { continue } # file chưa đổi: đã tìm rồi, không thấy
    $script:NameScanDone[$k] = $true
    try { $t = Read-Slice $f 0 $fi.Length } catch { continue }
    $i = $t.IndexOf($acct, $Ord)
    while ($i -ge 0) {
      $j = $t.IndexOf('email_address', $i, $Ord)
      if ($j -ge 0 -and $j - $i -lt 120) {
        $m = [regex]::Match($t.Substring($j, [Math]::Min(200, $t.Length - $j)), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
        if ($m.Success) { return $m.Value }
      }
      $i = $t.IndexOf($acct, $i + 1, $Ord)
    }
  }
  return $null
}
function Learn-DesktopNames([string]$dataDir, $ids) {
  try {
    $names = Read-AccountNames
    $cur = Desktop-Account $dataDir
    foreach ($a in $ids) {
      $k = $a.Substring(0, 8).ToLower()
      if ($names[$k] -and $names[$k] -ne $k) { continue }
      $dirs = @(); if ($a -eq $cur) { $dirs += $dataDir }; $dirs += (Join-Path $ProfileDir $a)
      foreach ($dir in $dirs) { $e = Find-EmailIn $dir $a; if ($e) { Set-AccountName $a $e.Split('@')[0]; break } }
    }
  } catch {}
}

function Account-Labels([string]$root) {
  $ids = @([IO.Directory]::GetDirectories($root) | ForEach-Object { Leaf $_ })
  Ensure-AccountsFile $ids
  Learn-CurrentName
  Learn-DesktopNames (Split-Path $root) $ids
  $names = Read-AccountNames
  $labels = @{}
  foreach ($a in $ids) { $k = $a.Substring(0, [Math]::Min(8, $a.Length)).ToLower(); $labels[$a] = $(if ($names[$k]) { $names[$k] } else { $a.Substring(0, [Math]::Min(8, $a.Length)) }) }
  return $labels
}

function Scan-Cards([string]$root) {
  $targets = New-Object System.Collections.Generic.List[object]
  $cards = [ordered]@{}
  $deleted = New-Object 'System.Collections.Generic.HashSet[string]'
  $labels = Account-Labels $root
  foreach ($ap in [IO.Directory]::GetDirectories($root)) {
    $acct = Leaf $ap
    foreach ($op in [IO.Directory]::GetDirectories($ap)) {
      $org = Leaf $op
      if ($org.StartsWith('deleted_')) { continue }
      $targets.Add(@{ dir = $op; acct = $acct; label = $labels[$acct] })
      foreach ($file in [IO.Directory]::GetFiles($op)) {
        $name = Leaf $file
        if ($name.StartsWith('deleted_')) {
          $id = $name.Substring(8) -replace '\.json$', ''
          [void]$deleted.Add($id); [void]$deleted.Add('local_' + $id)
          continue
        }
        if ($name -notmatch '^local_.*\.json$') { continue }
        try { $raw = Read-AllText $file } catch { continue }
        $data = Parse-Json $raw
        if (-not ($data -is [System.Collections.IDictionary])) { continue }
        $sid = Get-Key $data 'sessionId'; if (-not $sid) { $sid = $name -replace '\.json$', '' }
        $key = Get-Key $data 'cliSessionId'; if (-not $key) { $key = $sid }
        # chỉ dựa vào thời điểm hoạt động trong thẻ, không dùng ngày sửa file
        $stamp = To-Num (Get-Key $data 'lastActivityAt'); if (-not $stamp) { $stamp = To-Num (Get-Key $data 'createdAt') }
        if (-not $cards.Contains($key)) { $cards[$key] = New-Object System.Collections.Generic.List[object] }
        $mt = (New-Object IO.FileInfo((Long-Path $file))).LastWriteTimeUtc.Ticks
        $cards[$key].Add(@{ dir = $op; acct = $acct; label = $labels[$acct]; file = $file; name = $name; sid = $sid; stamp = $stamp; data = $data; raw = $raw; mtime = $mt })
      }
    }
  }
  return @{ targets = $targets; cards = $cards; deleted = $deleted; acctNow = (Desktop-Account (Split-Path $root)) }
}

function Newest-Copy($copies) {
  $n = $copies[0]
  foreach ($c in $copies) { if ($c.stamp -gt $n.stamp) { $n = $c } }
  return $n
}

# Tài khoản gốc: ưu tiên originAcct đã ghi trong thẻ; nếu chưa có thì createdAt nhỏ nhất
function Origin-Copy($copies) {
  foreach ($c in $copies) {
    $oa = Get-Key $c.data 'originAcct'
    if ($oa) {
      foreach ($x in $copies) { if ($x.acct -eq $oa) { return $x } }
      return $c
    }
  }
  $best = $copies[0]; $bv = [double]::PositiveInfinity
  foreach ($c in $copies) { $v = To-Num (Get-Key $c.data 'createdAt'); if (-not $v) { $v = [double]::PositiveInfinity }; if ($v -lt $bv) { $bv = $v; $best = $c } }
  return $best
}

function Is-Deleted($st, $copies) { foreach ($c in $copies) { if ($st.deleted.Contains([string]$c.sid)) { return $true } }; return $false }
function Cwd-Ok($copies) { foreach ($c in $copies) { $d = Get-Key $c.data 'cwd'; if ($d -and (Path-Exists $d)) { return $true } }; return $false }

# Tiêu đề đọc từ file chat (session terminal nhập bằng deep link thường thiếu tiêu đề trong thẻ)
function Title-Of([string]$cli) {
  if ($script:Index.Count -eq 0) { [void](Scan-Sessions) }
  foreach ($c in $script:Index.Values) { foreach ($p in $c.parts) { if ($p.id -eq $cli) { return $p.title } } }
  return $null
}

# skipDirs: thư mục KHÔNG ghi file (org đang đăng nhập — app đang giữ trong bộ nhớ)
function Plan-Sync($st, [string]$onlyCli, $skipDirs) {
  $ops = New-Object System.Collections.Generic.List[object]
  foreach ($key in @($st.cards.Keys)) {
    $copies = $st.cards[$key]
    if (Is-Deleted $st $copies) { continue }
    if ($onlyCli -and $key -ne $onlyCli) { continue }
    if (-not (Cwd-Ok $copies)) { continue } # thư mục project đã mất: không resume được ở đâu cả
    $newest = Newest-Copy $copies
    $originAcct = (Origin-Copy $copies).acct
    $title = Get-Key $newest.data 'title'
    if (-not $title) { foreach ($c in $copies) { $t = Get-Key $c.data 'title'; if ($t) { $title = $t; break } } }
    if (-not $title) { $title = Title-Of $key }
    # Chép vào MỌI org của mọi tài khoản (app chỉ đọc org đang hoạt động)
    foreach ($t in $st.targets) {
      if ($skipDirs -and $skipDirs.Contains($t.dir)) { continue }
      $have = @($copies | Where-Object { $_.dir -eq $t.dir })
      if ($have.Count) {
        # đã có: chỉ cập nhật thẻ cùng tên khi nó cũ hơn hoặc thiếu tiêu đề; khác tên thì để yên
        $same = $have | Where-Object { $_.name -eq $newest.name } | Select-Object -First 1
        if (-not $same) { continue }
        $newer = ($same.stamp -lt $newest.stamp) -and ($same.raw -cne $newest.raw)
        if (-not $newer -and ((Get-Key $same.data 'title') -or -not $title)) { continue }
      }
      $obj = New-Object 'System.Collections.Generic.Dictionary[string,object]'
      foreach ($k in @($newest.data.Keys)) { $obj[$k] = $newest.data[$k] }
      $obj['originAcct'] = [string]$originAcct
      if (-not (Get-Key $obj 'title') -and $title) { $obj['title'] = [string]$title }
      $ops.Add(@{ dest = (Join-Path $t.dir $newest.name); content = $Js.Serialize($obj); key = $key; label = $t.label })
    }
  }
  return ,$ops
}

# Tóm tắt cho người dùng: bao nhiêu session, sang tài khoản nào (bỏ tài khoản đang đăng nhập)
function Ops-Summary($ops, $meLabel) {
  $other = @($ops | Where-Object { $_.label -ne $meLabel })
  $accts = @($other | ForEach-Object { $_.label } | Sort-Object -Unique)
  return @{ sessions = @($other | ForEach-Object { $_.key } | Sort-Object -Unique).Count; accts = $accts; text = ($accts -join ', ') }
}

function Eligible-Count($st) {
  $n = 0
  foreach ($k in @($st.cards.Keys)) { $c = $st.cards[$k]; if (-not (Is-Deleted $st $c) -and (Cwd-Ok $c)) { $n++ } }
  return $n
}

function Cli-IdsInDesktop($st) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($copies in $st.cards.Values) { foreach ($c in $copies) { $x = Get-Key $c.data 'cliSessionId'; if ($x) { [void]$set.Add([string]$x) } } }
  return ,$set
}

# cliSessionId -> @{ origin = nhãn tài khoản gốc; accounts = [nhãn...] }
function Owner-Info($st) {
  $info = @{}
  foreach ($copies in $st.cards.Values) {
    $cli = Get-Key $copies[0].data 'cliSessionId'
    if (-not $cli) { continue }
    $info[[string]$cli] = @{ origin = (Origin-Copy $copies).label; accounts = @($copies | ForEach-Object { $_.label } | Select-Object -Unique) }
  }
  return $info
}

# Thư mục <tài khoản>\<org> Claude Desktop đang dùng. KHÔNG lấy từ ~/.claude.json: file đó của
# Claude Code CLI, app không cập nhật khi đổi tài khoản (đã dính: app đã sang tài khoản khác mà file vẫn ghi tài khoản cũ).
# - Tài khoản: lastKnownAccountUuid trong config.json của app ($st.acctNow) — chắc chắn.
# - Org: app ghi lại thẻ mỗi khi bạn bấm/dùng một session, và khi lưu nó BỎ trường lạ originAcct;
#   thẻ do tool chép thì luôn có originAcct => thẻ KHÔNG có originAcct được ghi gần nhất (trong tài
#   khoản đó) nằm ở org app đang dùng. Không đọc được config thì đoán như vậy trên mọi tài khoản.
function Active-Target($st) {
  $best = $null
  foreach ($copies in $st.cards.Values) {
    foreach ($c in $copies) {
      if (Get-Key $c.data 'originAcct') { continue }
      if ($st.acctNow -and $c.acct -ne $st.acctNow) { continue }
      if (-not $best -or $c.mtime -gt $best.mtime) { $best = $c }
    }
  }
  if ($best) { foreach ($t in $st.targets) { if ($t.dir -eq $best.dir) { return $t } } }
  # chưa có thẻ app tự ghi trong tài khoản này: chỉ chắc khi tài khoản có đúng 1 org
  $mine = @($st.targets | Where-Object { $_.acct -eq $st.acctNow })
  if ($st.acctNow -and $mine.Count -eq 1) { return $mine[0] }
  return $null
}

# ---- giới hạn sử dụng của từng tài khoản ----
# App tự ghi ~15 phút/lần vào <thư mục dữ liệu>\plan-usage-history.json, theo ORG:
# {"t":<ms>,"org":"<org>","u":{"fh":<% giới hạn 5 giờ>,"sd":<% giới hạn 7 ngày>}}. Chỉ có số khi
# tài khoản đó đang đăng nhập => tài khoản khác hiện số lần cuối kèm giờ. Org dùng chung cho nhiều
# tài khoản: gán theo nhật ký tài khoản đang dùng của tool, chưa có thì đoán theo thẻ app tự ghi.
$AccountLog = Join-Path $UserHome '.claude\cs-account-log.json'
function Read-AccountLog {
  try { if ([IO.File]::Exists($AccountLog)) { $o = Parse-Json (Read-AllText $AccountLog); if ($o -is [object[]]) { return ,$o } } } catch {}
  return ,@()
}
function Note-Account([string]$acct) {
  if (-not $acct) { return }
  $log = New-Object System.Collections.Generic.List[object]
  foreach ($e in (Read-AccountLog)) { $log.Add($e) }
  if ($log.Count -and (Get-Key $log[$log.Count - 1] 'acct') -eq $acct) { return }
  $log.Add([ordered]@{ t = (Now-Ms); acct = $acct })
  while ($log.Count -gt 500) { $log.RemoveAt(0) }
  try { [void][IO.Directory]::CreateDirectory((Split-Path $AccountLog)); Write-Atomic $AccountLog (To-JsonText $log) } catch {}
}
# nhãn tài khoản -> @{ t; fh; sd; guess }
function Usage-ByAccount([string]$root, $st) {
  $res = @{}
  $f = Join-Path (Split-Path $root) 'plan-usage-history.json'
  if (-not [IO.File]::Exists($f)) { return $res }
  $samples = Get-Key (Parse-Json (Read-AllText $f)) 'samples'
  if (-not $samples) { return $res }
  $orgAccts = @{}; $acts = @{}; $label = @{} # org -> [tài khoản]; "tài khoản|org" -> [lastActivityAt thẻ app tự ghi]
  foreach ($t in $st.targets) {
    $o = Leaf $t.dir; $label[$t.acct] = $t.label
    if (-not $orgAccts.ContainsKey($o)) { $orgAccts[$o] = New-Object System.Collections.Generic.List[string] }
    if (-not $orgAccts[$o].Contains($t.acct)) { $orgAccts[$o].Add($t.acct) }
  }
  foreach ($copies in $st.cards.Values) {
    foreach ($c in $copies) {
      if (Get-Key $c.data 'originAcct') { continue }
      $k = $c.acct + '|' + (Leaf $c.dir)
      if (-not $acts.ContainsKey($k)) { $acts[$k] = New-Object System.Collections.Generic.List[double] }
      $acts[$k].Add($c.stamp)
    }
  }
  $log = Read-AccountLog
  $done = @{}
  $oldest = (Now-Ms) - 30L * 86400000
  for ($i = $samples.Count - 1; $i -ge 0; $i--) {
    $s = $samples[$i]; $t = To-Num (Get-Key $s 't'); $org = [string](Get-Key $s 'org')
    if ($t -lt $oldest) { break }
    $cands = $orgAccts[$org]
    if (-not $cands) { continue }
    $acct = $null; $guess = $false
    if ($cands.Count -eq 1) { $acct = $cands[0] }
    else {
      # Mục nhật ký ngay trước lúc ghi số; không khớp org thì xét mục đầu tiên trong 2 phút SAU đó
      # (app ghi số ngay khi vừa đăng nhập, trước lúc tool kịp ghi nhật ký — thấy lệch ~10 giây)
      $before = $null; $after = $null
      foreach ($e in $log) {
        $et = To-Num (Get-Key $e 't')
        if ($et -le $t) { $before = $e } elseif (-not $after -and $et -le $t + 120000) { $after = $e }
      }
      foreach ($e in @($before, $after)) {
        if ($e -and $cands.Contains([string](Get-Key $e 'acct'))) { $acct = [string](Get-Key $e 'acct'); break }
      }
      if (-not $acct) {
        # tài khoản có hoạt động gần nhất (không quá 15 phút sau) thời điểm ghi số
        $bestT = 0
        foreach ($a in $cands) { foreach ($x in @($acts[$a + '|' + $org])) { if ($x -and $x -le $t + 900000 -and $x -gt $bestT) { $bestT = $x; $acct = $a } } }
        $guess = $true
      }
    }
    if ($acct -and -not $done.ContainsKey($acct)) {
      $done[$acct] = $true
      $u = Get-Key $s 'u'
      $res[$label[$acct]] = [ordered]@{ t = $t; fh = (Get-Key $u 'fh'); sd = (Get-Key $u 'sd'); guess = $guess }
    }
  }
  return $res
}

# ---- usage TRỰC TIẾP qua OAuth token (xem mục OAuth token ngay dưới) ----
# Số app tự ghi (Usage-ByAccount ở trên) chỉ mới khi app ghi mẫu (~15 phút/lần, CHỈ tài khoản đang
# đăng nhập) -> tài khoản khác luôn thấy số CŨ. Đây là mục đích chính người dùng cần: bấm đồng bộ là
# có số MỚI cho mọi tài khoản, không cần đổi tài khoản/tắt app.
# (24/10/2026: đã bỏ biến thể cookie `sessionKey` — người dùng báo không còn đúng nữa. Chỉ còn OAuth
# token. Hàm chung Find-Pct/Extract-Usage/Dump-UsageDebug giữ lại, OAuth token dùng tiếp ở dưới.)
# Dò đệ quy 1 số % trong JSON theo GỢI Ý tên khoá (chữ thường, không dấu cách) — chưa có mẫu JSON
# thật từ endpoint OAuth nên không hardcode đường dẫn cố định.
function Find-Pct($node, [string[]]$hints) {
  if ($node -is [System.Collections.IDictionary]) {
    foreach ($k in @($node.Keys)) {
      $kl = ([string]$k).ToLowerInvariant()
      foreach ($h in $hints) {
        if (-not $kl.Contains($h)) { continue }
        $v = $node[$k]
        if ($v -is [System.Collections.IDictionary]) {
          foreach ($sub in @('utilization', 'percent_used', 'percentage', 'percent', 'used_percent', 'pct')) {
            if ($v.ContainsKey($sub)) { return (To-Num $v[$sub]) }
          }
        } elseif ($v -ne $null -and -not ($v -is [System.Collections.IDictionary]) -and -not ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string]))) {
          return (To-Num $v)
        }
      }
    }
    foreach ($k in @($node.Keys)) { $r = Find-Pct $node[$k] $hints; if ($null -ne $r) { return $r } }
  } elseif ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
    foreach ($it in $node) { $r = Find-Pct $it $hints; if ($null -ne $r) { return $r } }
  }
  return $null
}
function Extract-Usage($raw) {
  if (-not $raw) { return $null }
  $fh = Find-Pct $raw @('five_hour', 'fivehour', 'fiveh', '5h')
  $sd = Find-Pct $raw @('seven_day', 'sevenday', 'sevend', '7d')
  if ($null -eq $fh -or $null -eq $sd) { return $null }
  return [ordered]@{ fh = [math]::Round($fh); sd = [math]::Round($sd) }
}
function Dump-UsageDebug([string]$acct, $raw) {
  try { Write-Atomic (Join-Path $UserHome ('.claude\cs-usage-debug-' + $acct + '.json')) $Js.Serialize($raw) } catch {}
}

# ---- usage TRỰC TIẾP qua OAuth token người dùng tự dán (23/10/2026, thay cho cookie từ 24/10/2026) ----
# Mục đích: số MỚI cho tài khoản KHÔNG đang dùng mà không cần đổi tài khoản/tắt app. Gọi endpoint
# OAuth: GET https://api.anthropic.com/api/oauth/usage kèm header Authorization: Bearer <token>.
# RANH GIỚI (giống ràng buộc 5 trong CLAUDE.md): tool KHÔNG tự đọc/giải mã token từ auth.json hay
# bất kỳ kho lưu trữ nào của app (config.json, Local State, Network\Cookies, IndexedDB…) — việc đó
# đã thử và bị bộ kiểm duyệt an toàn chặn, không làm lại. NGƯỜI DÙNG tự lấy giá trị token bằng công
# cụ của họ (vd script ngoài) rồi tự dán vào cs-profiles\<mã tài khoản>\oauth-token.txt — tool CHỈ
# đọc file text này.
# CHƯA XÁC NHẬN tên trường chính xác trong JSON trả về (chưa có mẫu thật) — Find-Pct dò theo từ
# khoá (không hardcode đường dẫn cố định); dò không ra thì KHÔNG đoán bừa — Dump-UsageDebug ghi
# nguyên văn JSON ra cs-usage-debug-<acct>.json (chỉ ở máy người dùng) để xem và chỉnh cho khớp.
function Token-Path([string]$acct) { return (Join-Path (Profile-Path $acct) 'oauth-token.txt') }
function Read-Token([string]$acct) {
  try {
    $f = Token-Path $acct
    if ([IO.File]::Exists($f)) { $v = (Read-AllText $f).Trim(); if ($v) { return $v } }
  } catch {}
  return $null
}
function Token-Accounts {
  if (-not [IO.Directory]::Exists($ProfileDir)) { return ,@() }
  return ,@([IO.Directory]::GetDirectories($ProfileDir) | ForEach-Object { Leaf $_ } |
    Where-Object { $_ -match $UuidRe -and [IO.File]::Exists((Token-Path $_)) })
}
# CHỈ ĐỌC (GET), không refresh/ghi gì phía app hay tài khoản. $null nếu không có gì để gọi;
# @{ok=$false; authError=$true} nếu token hết hạn/sai (401/403).
function Fetch-Usage-OAuth([string]$token) {
  if (-not $token) { return $null }
  try {
    $resp = Invoke-WebRequest -Uri 'https://api.anthropic.com/api/oauth/usage' `
      -Headers @{ Authorization = 'Bearer ' + $token; Accept = '*/*' } -UseBasicParsing -TimeoutSec 10
    return [ordered]@{ ok = $true; raw = (Parse-Json $resp.Content) }
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    return [ordered]@{ ok = $false; authError = ($code -eq 401 -or $code -eq 403); code = $code }
  }
}
# Gọi cho mọi tài khoản có oauth-token.txt, ghi đè vào $usage (cùng khoá theo nhãn, cùng hình dạng
# {t,fh,sd,guess,live} nên UI hiện sẵn không cần sửa). Lỗi xác thực thì giữ số cũ + đánh dấu tokenExpired.
function Overlay-LiveUsage-OAuth($usage, $st) {
  foreach ($acct in (Token-Accounts)) {
    $label = $(($st.targets | Where-Object { $_.acct -eq $acct } | Select-Object -First 1).label)
    if (-not $label) { continue }
    $token = Read-Token $acct
    if (-not $token) { continue }
    # Có file token cho tài khoản này => nếu $usage chưa có khoá (app chưa ghi số) vẫn tạo khung
    # rỗng để còn gắn cờ lỗi, nếu không UI không biết là đã thử live mà hỏng.
    if (-not $usage.Contains($label)) { $usage[$label] = [ordered]@{ t = (Now-Ms); fh = 0; sd = 0; guess = $false } }
    $r = Fetch-Usage-OAuth $token
    if (-not $r -or -not $r.ok) {
      # Lỗi xác thực (401/403) = token hết hạn. Lỗi khác (timeout/mạng/mã lạ, code=0) cũng phải báo,
      # không im lặng giữ số cũ (trước đây bấm ↻ "không ăn" mà không hiện lý do).
      if ($r -and $r.authError) { $usage[$label]['tokenExpired'] = $true }
      else { $usage[$label]['liveError'] = $true; $usage[$label]['liveErrCode'] = $(if ($r) { $r.code } else { 0 }) }
      continue
    }
    $u = Extract-Usage $r.raw
    if ($u) {
      $usage[$label] = [ordered]@{ t = (Now-Ms); fh = $u.fh; sd = $u.sd; guess = $false; live = $true }
    } else {
      Dump-UsageDebug $acct $r.raw
      $usage[$label]['tokenExpired'] = $false; $usage[$label]['liveUnmapped'] = $true
    }
  }
  return $usage
}

# Session cần nhập vào org đang đăng nhập bằng deep link
function Missing-In($st, [string]$dir) {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($key in @($st.cards.Keys)) {
    $copies = $st.cards[$key]
    if ($key -notmatch $UuidRe -or (Is-Deleted $st $copies) -or -not (Cwd-Ok $copies)) { continue }
    if (@($copies | Where-Object { $_.dir -eq $dir }).Count) { continue }
    $newest = Newest-Copy $copies
    if (Get-Key $newest.data 'isArchived') { continue } # deep link sẽ bỏ lưu trữ, nên để yên
    $t = Get-Key $newest.data 'title'
    $out.Add(@{ cli = $key; title = $(if ($t) { $t } else { $key }) })
  }
  return ,$out
}

# Chép đệ quy bằng .NET + \\?\ (Copy-Item của PowerShell 5.1 hỏng khi đường dẫn > 260 ký tự)
function Copy-Tree([string]$src, [string]$dst) {
  [void][IO.Directory]::CreateDirectory((Long-Path $dst))
  foreach ($f in [IO.Directory]::GetFiles((Long-Path $src))) { [IO.File]::Copy($f, (Long-Path (Join-Path $dst (Leaf $f))), $true) }
  foreach ($d in [IO.Directory]::GetDirectories((Long-Path $src))) { Copy-Tree ($d -replace '^\\\\\?\\', '') (Join-Path $dst (Leaf $d)) }
}
function Backup-Cards([string]$root) {
  $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ss-fffZ', $Inv)
  [void][IO.Directory]::CreateDirectory($BackupDir)
  Copy-Tree $root (Join-Path $BackupDir ('claude-code-sessions-' + $ts))
  $old = @([IO.Directory]::GetDirectories($BackupDir, 'claude-code-sessions-*') | Sort-Object -Descending)
  foreach ($d in ($old | Select-Object -Skip 5)) { [IO.Directory]::Delete('\\?\' + $d, $true) }
}

function Apply-Ops($ops) { foreach ($o in $ops) { Write-Atomic $o.dest $o.content } }

# Chỉ xét tiến trình tên "claude" (app Store: Claude.exe, bản .exe: claude.exe; Claude Code CLI cũng
# tên claude nhưng nằm chỗ khác nên lọc theo đường dẫn). Duyệt MỌI tiến trình để đọc Path mất ~1,5 s
# mỗi lần (đo 23/10/2026) — làm đổi tài khoản và menu tài khoản chậm hẳn; theo tên chỉ ~5 ms.
function Desktop-Procs {
  return @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*WindowsApps*Claude*' -or $_.Path -like '*AnthropicClaude*' })
}
function Desktop-Exe { $p = Desktop-Procs; if ($p.Count) { return $p[0].Path }; return $null }
function Quit-Desktop { Desktop-Procs | Stop-Process -Force -ErrorAction SilentlyContinue }
function Wait-Closed {
  for ($i = 0; $i -lt 100; $i++) {
    if (-not (Desktop-Exe)) { Start-Sleep -Milliseconds 300; return $true } # chờ Windows nhả hẳn file app vừa mở
    Start-Sleep -Milliseconds 150
  }
  return $false
}
# Mở link / app QUA explorer.exe, không Start-Process thẳng: chương trình con của PowerShell
# bám vào cửa sổ đen của tool — Claude/Chrome (Chromium) in log lỗi cache vào đó, và đóng cửa
# sổ tool có thể tắt luôn Claude Desktop vừa mở.
function Open-Detached([string]$target) { Start-Process explorer.exe -ArgumentList ('"' + $target + '"') }

function Launch-Desktop([string]$exe) {
  # 1) App cài từ Microsoft Store / MSIX: mở qua shell:AppsFolder
  try {
    $p = Get-AppxPackage | Where-Object { $_.PackageFamilyName -like 'Claude_*' } | Select-Object -First 1
    if ($p) {
      $a = (Get-AppxPackageManifest $p).Package.Applications.Application | Select-Object -First 1
      $aumid = $p.PackageFamilyName + '!' + $a.Id
      Open-Detached ('shell:AppsFolder\' + $aumid)
      Write-Host ('Mo Claude Desktop: shell:AppsFolder\' + $aumid)
      return $aumid
    }
  } catch {}
  # 2) App cài bằng file .exe
  foreach ($f in @($exe, (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'))) {
    if ($f -and [IO.File]::Exists($f)) { Open-Detached $f; Write-Host ('Mo Claude Desktop: ' + $f); return $f }
  }
  Write-Host 'Khong tim thay cach mo Claude Desktop.'
  return $null
}

# ---- nhập session vào app đang chạy, không restart ----
# claude://resume?session=<cli>: app đọc file chat, ghi thẻ local_<cli>.json vào org đang
# đăng nhập, thêm vào sidebar ngay và chuyển tới session đó. Đã có thì chỉ chuyển tới.
function Open-DeepLink([string]$cli) {
  if ($cli -notmatch $UuidRe) { throw 'Mã session không hợp lệ.' }
  Open-Detached ('claude://resume?session=' + $cli)
}
function Dirs-WithCard([string]$root, [string]$cli) {
  $name = 'local_' + $cli + '.json'
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($a in [IO.Directory]::GetDirectories($root)) {
    foreach ($o in [IO.Directory]::GetDirectories($a)) { if ([IO.File]::Exists((Long-Path (Join-Path $o $name)))) { $out.Add($o) } }
  }
  return ,$out
}
# Gọi deep link rồi chờ thẻ app ghi ra; trả thư mục org nơi thẻ mới xuất hiện (hoặc $null)
function Import-ViaDeepLink([string]$root, [string]$cli, [int]$waitMs) {
  $before = Dirs-WithCard $root $cli
  Open-DeepLink $cli
  $t0 = Now-Ms
  while ((Now-Ms) - $t0 -lt $waitMs) {
    Start-Sleep -Milliseconds 250
    foreach ($d in (Dirs-WithCard $root $cli)) { if (-not $before.Contains($d)) { return $d } }
  }
  return $null
}

# Gỡ thẻ. App không gỡ nóng được và GHI LẠI thẻ của session đang nạp khi bạn bấm vào nó,
# nên thẻ của tài khoản đang đăng nhập chỉ xoá khi app đã tắt hẳn: tắt -> xoá -> mở lại.
function Split-Victims($st, $victims) {
  $exe = Desktop-Exe
  $acct = $null
  if ($exe) { $a = Active-Target $st; if ($a) { $acct = $a.acct } }
  $live = @(if ($acct) { $victims | Where-Object { $_.acct -eq $acct } })
  $now = @($victims | Where-Object { $live -notcontains $_ })
  return @{ exe = $exe; live = $live; now = $now }
}
function Remove-Cards($st, $victims, [bool]$restart) {
  $sv = Split-Victims $st $victims
  $n = 0
  foreach ($v in $sv.now) { try { [IO.File]::Delete((Long-Path $v.file)); $n++ } catch {} }
  if (-not $sv.live.Count) { return @{ n = $n; note = 'Tài khoản khác thấy thay đổi khi bạn chuyển sang.' } }
  if (-not $restart) { return @{ n = $n; note = ([string]$sv.live.Count + ' thẻ ở tài khoản đang đăng nhập CHƯA gỡ (cần tắt Claude Desktop) — bấm Gỡ lại và chọn khởi động lại.') } }
  Quit-Desktop
  if (-not (Wait-Closed)) { return @{ n = $n; note = ('Không đóng được Claude Desktop nên chưa gỡ ' + $sv.live.Count + ' thẻ ở tài khoản đang đăng nhập.') } }
  foreach ($v in $sv.live) { try { [IO.File]::Delete((Long-Path $v.file)); $n++ } catch {} }
  $ok = Launch-Desktop $sv.exe
  return @{ n = $n; note = $(if ($ok) { 'Đã khởi động lại Claude Desktop — tài khoản đang đăng nhập không còn hiện các session này.' } else { 'Đã tắt Claude Desktop nhưng không mở lại được, hãy tự mở app.' }) }
}

# ================= đổi tài khoản Claude Desktop: bấm là vào, không đăng nhập lại =================
# Người dùng đồng ý (23/10/2026) cho tool giữ đăng nhập của từng tài khoản trên máy này.
# Đăng nhập của app nằm trong thư mục dữ liệu: token (app đã mã hoá) ở các khoá oauth:* của
# config.json, cookie claude.ai ở Network\Cookies, cùng vài kho lưu trữ web. Khoá giải mã (Local State)
# dùng chung cho mọi tài khoản trên máy nên chỉ cần TRÁO các phần này lúc app TẮT. Tool không đọc
# nội dung token, chỉ chép nguyên file. Session, cài đặt… không đụng tới.
# Hồ sơ: ~/.claude/cs-profiles\<mã tài khoản>. Đừng bấm Đăng xuất trong app: đăng xuất huỷ token phía
# máy chủ, hồ sơ đã lưu thành vô dụng — "Đăng xuất" của tool chỉ cất đăng nhập sang một bên.
$ProfileDir = Join-Path $UserHome '.claude\cs-profiles'
$AuthPaths = @('Network\Cookies', 'Network\Cookies-journal', 'Local Storage', 'Session Storage', 'IndexedDB')
# bootSidebarPlaceholder/bootSideSessions: sidebar app vẽ tạm lúc khởi động — đi theo tài khoản
function Is-AuthKey([string]$k) { return $k.StartsWith('oauth:') -or $k -eq 'lastKnownAccountUuid' -or $k -eq 'bootSidebarPlaceholder' -or $k -eq 'bootSideSessions' }

function Desktop-DataDir { $r = Desktop-Root; if ($r) { return (Split-Path $r) }; return $null }
function Read-DesktopConfig([string]$dataDir) {
  $f = Join-Path $dataDir 'config.json'
  if (-not [IO.File]::Exists($f)) { return $null }
  $o = Parse-Json (Read-AllText $f)
  if ($o -is [System.Collections.IDictionary]) { return ,$o }
  return $null
}
# Tài khoản app đang đăng nhập (app ghi lastKnownAccountUuid khi đăng nhập)
function Desktop-Account([string]$dataDir) {
  try { $a = [string](Get-Key (Read-DesktopConfig $dataDir) 'lastKnownAccountUuid'); if ($a -match $UuidRe) { return $a } } catch {}
  return $null
}
function Has-Login($cfg) {
  if (-not $cfg) { return $false }
  foreach ($k in @($cfg.Keys)) { if ($k.StartsWith('oauth:token') -and $cfg[$k]) { return $true } }
  return $false
}
# Đổi tên/chép file ngay sau khi tắt app có thể bị khoá vài giây (antivirus/Windows quét file vừa
# ghi) dù Wait-Closed đã chờ 300ms — dính thật 23/10/2026 ("Access ... is denied" lúc Move hồ sơ,
# tự hết sau vài giây, thử tay lại được ngay). Thử lại thay vì báo lỗi ngay cho người dùng.
function Retry-FsOp([scriptblock]$op, [int]$tries = 10, [int]$delayMs = 300) {
  for ($i = 0; $i -lt $tries; $i++) {
    try { & $op; return } catch { if ($i -eq $tries - 1) { throw }; Start-Sleep -Milliseconds $delayMs }
  }
}
function Remove-Any([string]$p) {
  $lp = Long-Path $p
  if ([IO.Directory]::Exists($lp)) { [IO.Directory]::Delete($lp, $true) } elseif ([IO.File]::Exists($lp)) { [IO.File]::Delete($lp) }
}
function Copy-Any([string]$src, [string]$dst) {
  if ([IO.Directory]::Exists((Long-Path $src))) { Copy-Tree $src $dst; return }
  if ([IO.File]::Exists((Long-Path $src))) { [void][IO.Directory]::CreateDirectory((Split-Path $dst)); [IO.File]::Copy((Long-Path $src), (Long-Path $dst), $true) }
}
function Profile-Path([string]$acct) { return (Join-Path $ProfileDir $acct) }
function Profile-SavedAt([string]$acct) {
  try { return [long][IO.File]::ReadAllText((Join-Path (Profile-Path $acct) 'saved.txt'), $Utf8).Trim() } catch { return $null }
}
function Profile-Ids {
  if (-not [IO.Directory]::Exists($ProfileDir)) { return ,@() }
  return ,@([IO.Directory]::GetDirectories($ProfileDir) | ForEach-Object { Leaf $_ } | Where-Object { $_ -match $UuidRe -and [IO.File]::Exists((Join-Path (Profile-Path $_) 'auth.json')) })
}

# Cất đăng nhập hiện tại của app thành hồ sơ của $acct (app phải đang tắt). Bản trước giữ ở .prev.
function Save-Profile([string]$dataDir, [string]$acct) {
  $cfg = Read-DesktopConfig $dataDir
  if (-not (Has-Login $cfg)) { return $false } # đang ở màn đăng nhập: không có gì để cất, đừng đè hồ sơ tốt
  $dest = Profile-Path $acct; $tmp = $dest + '.cs-tmp'
  Retry-FsOp { Remove-Any $tmp }
  [void][IO.Directory]::CreateDirectory($tmp)
  foreach ($p in $AuthPaths) { Retry-FsOp { Copy-Any (Join-Path $dataDir $p) (Join-Path $tmp $p) } }
  $auth = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  foreach ($k in @($cfg.Keys)) { if (Is-AuthKey $k) { $auth[$k] = $cfg[$k] } }
  [IO.File]::WriteAllText((Join-Path $tmp 'auth.json'), $Js.Serialize($auth), $Utf8)
  [IO.File]::WriteAllText((Join-Path $tmp 'saved.txt'), [string](Now-Ms), $Utf8)
  Retry-FsOp { Remove-Any ($dest + '.prev') }
  if ([IO.Directory]::Exists($dest)) { Retry-FsOp { [IO.Directory]::Move($dest, $dest + '.prev') } }
  Retry-FsOp { [IO.Directory]::Move($tmp, $dest) }
  return $true
}
# Thay phần đăng nhập trong thư mục app bằng hồ sơ $src ($src rỗng: bỏ đăng nhập -> app hiện màn
# đăng nhập, KHÔNG huỷ token phía máy chủ như nút Đăng xuất). Các khoá khác của config.json giữ nguyên.
function Set-AuthState([string]$dataDir, [string]$src) {
  $auth = $null
  if ($src) {
    $auth = Parse-Json (Read-AllText (Join-Path $src 'auth.json'))
    if (-not ($auth -is [System.Collections.IDictionary])) { throw 'Hồ sơ đăng nhập bị hỏng — đăng nhập lại tài khoản này một lần.' }
  }
  foreach ($p in $AuthPaths) {
    Retry-FsOp { Remove-Any (Join-Path $dataDir $p) }
    if ($src) { Retry-FsOp { Copy-Any (Join-Path $src $p) (Join-Path $dataDir $p) } }
  }
  $cfg = Read-DesktopConfig $dataDir
  $out = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  if ($cfg) { foreach ($k in @($cfg.Keys)) { if (-not (Is-AuthKey $k)) { $out[$k] = $cfg[$k] } } }
  if ($auth) { foreach ($k in @($auth.Keys)) { $out[$k] = $auth[$k] } }
  Write-Atomic (Join-Path $dataDir 'config.json') ($Js.Serialize($out))
}

function Accounts-Info {
  $dd = Desktop-DataDir
  if (-not $dd) { return [ordered]@{ desk = $false; accounts = @() } }
  $root = Join-Path $dd 'claude-code-sessions'
  $st = Scan-Cards $root
  $cur = Desktop-Account $dd
  $loggedIn = Has-Login (Read-DesktopConfig $dd)
  $labels = Account-Labels $root
  $names = Read-AccountNames
  $profiles = Profile-Ids
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($a in @(@($cur) + @($st.targets | ForEach-Object { $_.acct }) + $profiles)) { if ($a -and -not $ids.Contains($a)) { $ids.Add($a) } }
  # lần gần nhất tài khoản được dùng (theo nhật ký) — để báo "app chưa ghi số cho lần vào này"
  $lastSeen = @{}
  foreach ($e in (Read-AccountLog)) { $lastSeen[[string](Get-Key $e 'acct')] = To-Num (Get-Key $e 't') }
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($a in $ids) {
    $k = $a.Substring(0, 8).ToLower()
    $list.Add([ordered]@{
      id = $a; label = $(if ($labels[$a]) { $labels[$a] } elseif ($names[$k]) { $names[$k] } else { $k })
      current = ($loggedIn -and $a -eq $cur); saved = ($profiles -contains $a); savedAt = (Profile-SavedAt $a)
      lastSeen = $lastSeen[$a]
    })
  }
  return [ordered]@{ desk = $true; loggedIn = $loggedIn; running = [bool](Desktop-Exe); accounts = $list }
}

# $target = mã tài khoản: vào tài khoản đó; rỗng: bỏ đăng nhập để đăng nhập tài khoản mới.
# Tắt app -> cất đăng nhập hiện tại vào hồ sơ của nó -> đặt hồ sơ đích vào -> mở lại app.
# CS_DESKTOP_DIR (chế độ thử trên bản chép): không tắt/mở app thật.
function Switch-Account([string]$target) {
  $dd = Desktop-DataDir
  if (-not $dd) { throw 'Không tìm thấy dữ liệu Claude Desktop.' }
  $test = [bool]$env:CS_DESKTOP_DIR
  if ($target -and -not (Profile-Ids).Contains($target)) { throw 'Tài khoản này chưa có đăng nhập đã lưu — đăng nhập nó một lần trước.' }
  $exe = Desktop-Exe
  if ($exe -and -not $test) {
    Quit-Desktop
    if (-not (Wait-Closed)) { throw 'Không đóng được Claude Desktop. Tắt tay rồi bấm lại.' }
  }
  $cur = Desktop-Account $dd
  $saved = $false
  try {
    if ($cur) { $saved = Save-Profile $dd $cur }
    if ($target) { Set-AuthState $dd (Profile-Path $target); Note-Account $target } else { Set-AuthState $dd $null }
  } catch {
    if (-not $test) { [void](Launch-Desktop $exe) }
    throw ('Chưa đổi được tài khoản: ' + $_.Exception.Message)
  }
  $launched = $test -or [bool](Launch-Desktop $exe)
  return @{ cur = $cur; saved = $saved; launched = $launched }
}

# ================= server =================
function Send-Bytes($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
  $r = $ctx.Response
  $r.StatusCode = $code
  $r.ContentType = $type
  $r.ContentLength64 = $bytes.Length
  $r.OutputStream.Write($bytes, 0, $bytes.Length)
  $r.OutputStream.Close()
}
function Send-Json($ctx, [int]$code, $obj) { Send-Bytes $ctx $code 'application/json; charset=utf-8' ($Utf8.GetBytes((To-JsonText $obj))) }
function Read-Body($ctx) {
  $sr = New-Object IO.StreamReader($ctx.Request.InputStream, $Utf8)
  $b = $sr.ReadToEnd()
  $o = Parse-Json $b
  if ($o -is [System.Collections.IDictionary]) { return $o }
  return @{}
}

function Handle-Request($ctx) {
  $req = $ctx.Request
  $path = $req.Url.AbsolutePath
  $method = $req.HttpMethod
  $q = $req.QueryString
  # Chỉ nhận trình duyệt gọi đúng 127.0.0.1/localhost (chặn "DNS rebinding")
  $hostHdr = $req.Headers['Host']
  if (-not $hostHdr) { $hostHdr = $req.UserHostName }
  if ($hostHdr -ne "127.0.0.1:$Port" -and $hostHdr -ne "localhost:$Port") { return Send-Json $ctx 403 @{ error = 'Sai địa chỉ.' } }

  if ($method -eq 'GET' -and $path -eq '/') {
    $html = [IO.File]::ReadAllText($UiFile, $Utf8).Replace('__TOKEN__', $Token)
    return Send-Bytes $ctx 200 'text/html; charset=utf-8' ($Utf8.GetBytes($html))
  }
  if (-not $path.StartsWith('/api/')) { return Send-Json $ctx 404 @{ error = 'Không có trang này.' } }
  if ($req.Headers['X-Token'] -ne $Token) { return Send-Json $ctx 403 @{ error = 'Tải lại trang để tiếp tục.' } }

  if ($method -eq 'GET' -and $path -eq '/api/sessions') {
    $inDesk = $null; $owners = @{}; $me = $null; $accts = @(); $usage = @{}
    try {
      $r = Desktop-Root
      if ($r) {
        $st = Scan-Cards $r
        $inDesk = Cli-IdsInDesktop $st
        $owners = Owner-Info $st
        $t = Active-Target $st
        if ($t) { $me = $t.label; Note-Account $t.acct } # nhãn của tài khoản đang đăng nhập trong Claude Desktop
        $accts = @($st.targets | ForEach-Object { $_.label } | Sort-Object -Unique)
        try { $usage = Usage-ByAccount $r $st } catch {}
        try { $usage = Overlay-LiveUsage-OAuth $usage $st } catch {}
      }
    } catch {}
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($c in (Scan-Sessions)) {
      $o = $owners[$c.id]
      $origin = $null; $acc = @()
      if ($o) { $origin = $o.origin; $acc = @($o.accounts) }
      $list.Add([ordered]@{
        id = $c.id; title = $c.title; cwd = $c.cwd; project = $c.project; branch = $c.branch
        mtime = $c.mtime; mb = $c.mb; exists = $c.exists; count = $c.count
        desktop = [bool]($inDesk -and $inDesk.Contains($c.id))
        origin = $origin; accounts = $acc
      })
    }
    return Send-Json $ctx 200 ([ordered]@{ account = $me; me = $me; accts = $accts; usage = $usage; root = $Root; desk = [bool]$r; sessions = $list })
  }

  if ($path -eq '/api/restart') {
    $exe = Desktop-Exe
    if (-not $exe) {
      if (-not (Launch-Desktop $null)) { return Send-Json $ctx 500 @{ error = 'Claude Desktop đang tắt và không mở được. Hãy tự mở app.' } }
      return Send-Json $ctx 200 @{ message = 'Claude Desktop đang tắt — đã mở giúp.' }
    }
    Quit-Desktop
    if (-not (Wait-Closed)) { return Send-Json $ctx 500 @{ error = 'Không đóng được Claude Desktop. Tắt tay rồi mở lại giúp.' } }
    if (-not (Launch-Desktop $exe)) { return Send-Json $ctx 500 @{ error = 'Đã đóng nhưng không mở lại được. Hãy tự mở Claude Desktop.' } }
    return Send-Json $ctx 200 @{ message = 'Đã khởi động lại Claude Desktop. Danh sách session giờ đã cập nhật.' }
  }

  # Org đang đăng nhập nhận session qua deep link (hiện ngay); tài khoản/org khác nhận
  # file thẻ (hiện khi chuyển sang tài khoản đó). App tắt thì chép file vào hết.
  if ($path -eq '/api/sync-all') {
    $root = Desktop-Root
    if (-not $root) { return Send-Json $ctx 400 @{ error = 'Chưa thấy dữ liệu Claude Desktop nên chưa có session nào trong app để thêm. Mở từng session bằng nút “Mở trong Claude Desktop”.' } }
    $st = Scan-Cards $root
    $running = [bool](Desktop-Exe)
    $active = $(if ($running) { Active-Target $st } else { $null })
    $skip = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($active) { [void]$skip.Add($active.dir) }
    $links = @()
    if ($active) { $links = Missing-In $st $active.dir }
    $ops = Plan-Sync $st $null $skip
    $me = $(if ($active) { $active.label } else { $null })
    if ($method -eq 'GET') {
      $sum = Ops-Summary $ops $me
      return Send-Json $ctx 200 ([ordered]@{ total = (Eligible-Count $st); links = $links.Count; copies = $ops.Count
        copySessions = $sum.sessions; copyAccts = $sum.accts; me = $me; running = $running; hot = [bool]$active })
    }
    if (-not $ops.Count -and -not $links.Count) { return Send-Json $ctx 200 @{ message = 'Mọi tài khoản đã có đủ session rồi.' } }
    Backup-Cards $root
    $added = 0; $failed = New-Object System.Collections.Generic.List[string]
    foreach ($l in $links) {
      $dir = Import-ViaDeepLink $root $l.cli 12000
      if ($dir) { $added++; [void]$skip.Add($dir) } else { $failed.Add([string]$l.title) }
      Start-Sleep -Milliseconds 300
    }
    $ops2 = Plan-Sync (Scan-Cards $root) $null $skip # tính lại sau khi app đã ghi thẻ mới
    Apply-Ops $ops2
    $msg = New-Object System.Collections.Generic.List[string]
    if ($added) { $msg.Add('Đã thêm ' + $added + ' session vào ' + $(if ($me) { $me } else { 'tài khoản đang đăng nhập' }) + ' — hiện ngay, không cần khởi động lại.') }
    if ($failed.Count) { $msg.Add([string]$failed.Count + ' session app chưa nhận: ' + (@($failed | Select-Object -First 3) -join ', ') + $(if ($failed.Count -gt 3) { '…' } else { '' }) + '.') }
    $sum = Ops-Summary $ops2 $me
    if ($ops2.Count) { $msg.Add('Đã chép ' + $sum.sessions + ' session sang ' + $(if ($sum.text) { $sum.text } else { 'các tài khoản khác' }) + $(if ($running -and -not $active) { '. ' + $RELOAD_MSG } else { ' — thấy khi bạn chuyển sang tài khoản đó.' })) }
    if (-not $running) { $msg.Add('Claude Desktop đang tắt — mở app là thấy đủ.') }
    return Send-Json $ctx 200 @{ message = $(if ($msg.Count) { $msg -join ' ' } else { 'Không có gì thay đổi.' }) }
  }

  # Gỡ HÀNG LOẠT: với mọi session, xóa thẻ khỏi các tài khoản không phải gốc.
  if ($path -eq '/api/remove-all-others') {
    $root = Desktop-Root
    if (-not $root) { return Send-Json $ctx 400 @{ error = 'Không tìm thấy dữ liệu Claude Desktop.' } }
    $st = Scan-Cards $root
    $victims = New-Object System.Collections.Generic.List[object]
    foreach ($copies in $st.cards.Values) {
      if ($copies.Count -lt 2) { continue }
      $origin = Origin-Copy $copies
      foreach ($c in $copies) { if ($c.acct -ne $origin.acct) { $victims.Add($c) } }
    }
    if (-not $victims.Count) { return Send-Json $ctx 200 @{ message = 'Không có gì để gỡ — mọi session đã chỉ ở tài khoản gốc.' } }
    if ($method -eq 'GET') { return Send-Json $ctx 200 @{ count = $victims.Count; live = (Split-Victims $st $victims).live.Count } }
    $body = Read-Body $ctx
    Backup-Cards $root
    $r = Remove-Cards $st $victims ([bool](Get-Key $body 'restart'))
    return Send-Json $ctx 200 @{ message = ('Đã gỡ ' + $r.n + ' thẻ khỏi các tài khoản không phải gốc. ' + $r.note) }
  }

  # Gỡ một session khỏi mọi tài khoản TRỪ tài khoản gốc.
  if ($path -eq '/api/remove-others') {
    $body = $(if ($method -eq 'POST') { Read-Body $ctx } else { @{} })
    $id = $(if ($method -eq 'POST') { [string](Get-Key $body 'id') } else { [string]$q['id'] })
    if ($id -notmatch $IdRe) { return Send-Json $ctx 400 @{ error = 'Mã session không hợp lệ.' } }
    $root = Desktop-Root
    if (-not $root) { return Send-Json $ctx 400 @{ error = 'Không tìm thấy dữ liệu Claude Desktop.' } }
    $st = Scan-Cards $root
    if (-not $st.cards.Contains($id)) { return Send-Json $ctx 400 @{ error = 'Session này không có trong Claude Desktop.' } }
    $copies = $st.cards[$id]
    $origin = Origin-Copy $copies
    $victims = @($copies | Where-Object { $_.acct -ne $origin.acct })
    if (-not $victims.Count) { return Send-Json $ctx 200 @{ message = 'Session chỉ có ở tài khoản gốc, không cần gỡ.' } }
    if ($method -eq 'GET') { return Send-Json $ctx 200 @{ count = $victims.Count; live = (Split-Victims $st $victims).live.Count } }
    Backup-Cards $root
    $r = Remove-Cards $st $victims ([bool](Get-Key $body 'restart'))
    return Send-Json $ctx 200 @{ message = ('Đã gỡ ' + $r.n + ' thẻ. Gốc: ' + $origin.label + '. ' + $r.note) }
  }

  if ($method -eq 'GET' -and $path -eq '/api/preview') {
    $id = [string]$q['id']
    if (-not $script:Index.Contains($id)) { return Send-Json $ctx 404 @{ error = 'Không tìm thấy session.' } }
    return Send-Json $ctx 200 @{ messages = (Chain-Messages $script:Index[$id] 3 12) }
  }

  # Mở một session trong Claude Desktop (kể cả session tạo từ terminal): deep link nhập
  # nó vào tài khoản đang đăng nhập và mở luôn; đồng thời chép thẻ sang tài khoản khác.
  if ($path -eq '/api/open-desktop') {
    $id = $(if ($method -eq 'POST') { [string](Get-Key (Read-Body $ctx) 'id') } else { [string]$q['id'] })
    if ($id -notmatch $UuidRe) { return Send-Json $ctx 400 @{ error = 'Mã session không hợp lệ.' } }
    $root = Desktop-Root
    if (-not $script:Index.Contains($id)) { [void](Scan-Sessions) }
    $s = $script:Index[$id]
    $st = $null; $copies = @()
    if ($root) { $st = Scan-Cards $root; if ($st.cards.Contains($id)) { $copies = $st.cards[$id] } }
    $cwd = $null
    if ($s) { $cwd = $s.cwd } elseif ($copies.Count) { $cwd = Get-Key $copies[0].data 'cwd' }
    if (-not $cwd -or -not (Path-Exists $cwd)) { return Send-Json $ctx 400 @{ error = 'Thư mục project không còn tồn tại nên không mở lại được.' } }
    if (-not $root -and -not (Desktop-Installed)) { return Send-Json $ctx 400 @{ error = 'Chưa thấy Claude Desktop trên máy này — cài Claude Desktop rồi thử lại.' } }
    if ($method -eq 'GET') { return Send-Json $ctx 200 @{} }
    $t = 'session này'
    if ($copies.Count -and (Get-Key $copies[0].data 'title')) { $t = Get-Key $copies[0].data 'title' } elseif ($s) { $t = $s.title }
    if (-not $root) {
      # Chưa có thư mục thẻ (chưa từng dùng Claude Code trong app, hoặc app để dữ liệu ở chỗ tool
      # chưa biết): deep link vẫn nhập session vào tài khoản đang đăng nhập — app tự tạo thư mục.
      # Chỉ không chép sang tài khoản khác được.
      Open-DeepLink $id
      return Send-Json $ctx 200 @{ message = ('Đang mở “' + $t + '” trong Claude Desktop (tài khoản đang đăng nhập). Tool chưa thấy thư mục dữ liệu của app nên chưa chép sang tài khoản khác.') }
    }
    Backup-Cards $root
    if (-not (Desktop-Exe)) {
      # App tắt: chép thẻ trước, deep link sẽ mở app; app nạp xong mới nhập nên không trùng
      Apply-Ops (Plan-Sync $st $id $null)
      Open-DeepLink $id
      return Send-Json $ctx 200 @{ message = ('Đang mở Claude Desktop tới “' + $t + '”.') }
    }
    $active = Active-Target $st
    $skip = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($active) { [void]$skip.Add($active.dir) }
    if ($active -and @($copies | Where-Object { $_.dir -eq $active.dir }).Count) {
      Open-DeepLink $id # đã có ở tài khoản này: app chỉ chuyển tới
    } else {
      $dir = Import-ViaDeepLink $root $id 10000
      if ($dir) { [void]$skip.Add($dir) }
      elseif (-not $active) { return Send-Json $ctx 500 @{ error = 'Claude Desktop chưa nhận session (không rõ tài khoản đang đăng nhập). Bấm lại thử xem.' } }
    }
    $ops = Plan-Sync (Scan-Cards $root) $id $skip
    Apply-Ops $ops
    $me = $(if ($active) { $active.label } else { $null })
    $sum = Ops-Summary $ops $me
    $m = 'Đã mở “' + $t + '” ở ' + $(if ($me) { $me } else { 'tài khoản đang đăng nhập' }) + ' — không cần khởi động lại.'
    if ($sum.accts.Count) { $m += ' Session này cũng đã được chép sang ' + $sum.text + ' (thấy khi chuyển sang).' }
    return Send-Json $ctx 200 @{ message = $m }
  }

  if ($method -eq 'GET' -and $path -eq '/api/accounts') { return Send-Json $ctx 200 (Accounts-Info) }

  if ($method -eq 'POST' -and $path -eq '/api/account-name') {
    $b = Read-Body $ctx
    $acct = [string](Get-Key $b 'acct'); $name = ([string](Get-Key $b 'name') -replace '[\r\n=#]', ' ').Trim()
    if ($acct -notmatch $UuidRe) { return Send-Json $ctx 400 @{ error = 'Mã tài khoản không hợp lệ.' } }
    if (-not $name -or $name.Length -gt 40) { return Send-Json $ctx 400 @{ error = 'Tên phải từ 1 đến 40 ký tự.' } }
    Set-AccountName $acct $name
    return Send-Json $ctx 200 @{ message = ('Đã đặt tên: ' + $name) }
  }

  # Vào một tài khoản đã lưu (acct) hoặc bỏ đăng nhập để đăng nhập tài khoản mới (acct rỗng)
  if ($method -eq 'POST' -and $path -eq '/api/switch') {
    $acct = [string](Get-Key (Read-Body $ctx) 'acct')
    if ($acct -and $acct -notmatch $UuidRe) { return Send-Json $ctx 400 @{ error = 'Mã tài khoản không hợp lệ.' } }
    $r = Switch-Account $acct
    $names = Account-Labels (Desktop-Root)
    $curName = $(if ($r.cur -and $names[$r.cur]) { $names[$r.cur] } else { 'tài khoản cũ' })
    $m = $(if ($acct) { 'Đã vào ' + $(if ($names[$acct]) { $names[$acct] } else { 'tài khoản' }) + '.' } else { 'Claude Desktop đang ở màn đăng nhập — đăng nhập tài khoản mới (một lần), lần sau chọn trong tool là vào.' })
    if ($r.saved) { $m += ' Đăng nhập của ' + $curName + ' đã được cất, chọn lại lúc nào cũng được.' }
    if (-not $r.launched) { $m += ' Chưa mở lại được Claude Desktop, hãy tự mở app.' }
    return Send-Json $ctx 200 @{ message = $m }
  }

  return Send-Json $ctx 404 @{ error = 'Không có API này.' }
}

# Cho phép nạp hàm để kiểm thử: . .\cs-gui.ps1  (không chạy server)
if ($MyInvocation.InvocationName -eq '.') { return }

$Url = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Url)
# Chữ trong cửa sổ đen để KHÔNG DẤU: font mặc định (Raster) của cửa sổ đen không có dấu
# tiếng Việt, in ra thành "?". Giao diện web vẫn có dấu đầy đủ.
try { $listener.Start() } catch {
  Write-Host ('Tool dang chay san (hoac cong ' + $Port + ' ban), mo lai trinh duyet: ' + $Url)
  Open-Detached $Url
  exit 0
}
Write-Host ('Kho session Claude (ban PowerShell) dang chay: ' + $Url)
Write-Host ('Thu muc session: ' + $Root)
$deskRoot = Desktop-Root
if ($deskRoot) { Write-Host ('Thu muc Claude Desktop: ' + $deskRoot) }
else { Write-Host ('Chua thay thu muc Claude Desktop, da tim o: ' + ((Desktop-DataDirs) -join ' ; ')) }
Write-Host 'Dong cua so nay (hoac Ctrl+C) de tat tool.'
# Quét sẵn TRƯỚC khi mở trình duyệt: trang hiện ra là có dữ liệu ngay. Có cache trên đĩa thì
# chỉ quét lại các file chat đã đổi kể từ lần trước.
Load-SessionCache
$warm = [Diagnostics.Stopwatch]::StartNew()
Write-Host 'Dang doc danh sach session...'
try { [void](Scan-Sessions) } catch {}
Write-Host ('Xong (' + $warm.ElapsedMilliseconds + ' ms).')
if (-not $env:CS_NO_BROWSER) { Open-Detached $Url }

try {
  while ($listener.IsListening) {
    $ar = $listener.BeginGetContext($null, $null)
    while (-not $ar.AsyncWaitHandle.WaitOne(500)) { } # chờ từng nhịp để Ctrl+C còn tác dụng
    $ctx = $listener.EndGetContext($ar)
    try { Handle-Request $ctx }
    catch {
      Write-Host ('Loi: ' + $_.Exception.Message)
      try { Send-Json $ctx 500 @{ error = $_.Exception.Message } } catch {}
    }
  }
} finally { $listener.Close() }
