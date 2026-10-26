# Dự án: Tool "Kho session Claude" — chia sẻ session Claude Code giữa nhiều tài khoản trên một máy

Tài liệu này tóm tắt bối cảnh để một phiên Claude khác tiếp tục phát triển/sửa tool. Đọc kỹ
phần "Ràng buộc đã kiểm chứng" trước khi đề xuất cách làm mới — nhiều hướng đã thử và thất bại.

## Mục tiêu của người dùng
Một người dùng nhiều tài khoản Claude trên **cùng một máy Windows** (đổi tài khoản khi hết
limit). Đổi tài khoản trong Claude Desktop thì sidebar chỉ hiện session của tài khoản đó.
Muốn: mọi tài khoản cùng thấy chung danh sách session, mở lại được session cũ với đầy đủ ngữ
cảnh — và **không phải khởi động lại Claude Desktop** (đã đạt, xem mục Deep link).

## Cách Claude Desktop lưu session (đã xác minh trên máy thật)
- **Nội dung chat thật**: `~/.claude/projects/<slug>/<cliSessionId>.jsonl`. Dùng chung cho mọi tài khoản.
- **Thẻ session (metadata)**: `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code-sessions\<accountId>\<orgId>\local_<uuid>.json`
  - Mỗi file `local_*.json` là một mục trong sidebar, trỏ tới file chat qua `cliSessionId`.
  - 2 tầng: **tài khoản** → **org**. App chỉ đọc org đang hoạt động.
  - Trường chính: `sessionId` (= tên file), `cliSessionId`, `cwd`, `title`, `lastActivityAt`, `createdAt`, `isArchived`.
  - File `deleted_*` = session đã xóa.
- **Thư mục dữ liệu app KHÔNG cố định** (người dùng báo 20/10/2026: tool hiện "Không tìm thấy dữ liệu của
  Claude Desktop trên máy này", mọi session "chưa có trong app"). Đọc mã app 2.42304 (`[user-data-move]`,
  `index.pre.ts`) + `AppxManifest.xml`: bản Store trên Windows 11 (build ≥ 22000), bật theo đợt
  (`userDataOutsidePackageAnswer`), CHUYỂN (đổi tên) cả thư mục `LocalCache\Roaming\Claude` ra
  `%LOCALAPPDATA%\Claude-Data\<packageFamily viết thường>\` (vd `claude_pzs8sxrjxfjjc`) — đường dẫn THẬT
  (manifest loại khỏi ảo hoá). Chỗ cũ mất; có thể chuyển ngược lại. Các chỗ khác: `%APPDATA%\Claude`
  (bản .exe), `%LOCALAPPDATA%\Claude-3p` (chế độ 3P). `CLAUDE_USER_DATA_DIR`: bản ký số (bản người dùng cài) BỎ QUA biến này (mã app:
  `ignoredUserDataDirEnv`, log "signed builds ignore it") — chỉ bản dev dùng; đừng định làm "hồ sơ
  theo tài khoản" bằng biến này (đã đọc 23/10/2026).
  => `Desktop-DataDirs` liệt kê mọi chỗ; `Desktop-Root` chọn chỗ có `claude-code-sessions`, nhiều chỗ thì
  chỗ có thẻ ghi gần nhất. Máy này: 20/10/2026 chưa chuyển; 23/10/2026 ĐÃ chuyển sang
  `Claude-Data\claude_pzs8sxrjxfjjc` (chỗ cũ chỉ còn file đánh dấu `.user-data-left.*`).
- Trong thư mục dữ liệu app (đã xem 23/10/2026, chưa dùng trong tool): `config.json` có
  `lastKnownAccountUuid` (tài khoản đang đăng nhập — chắc hơn `Active-Target`) và token đã mã hoá
  (`oauth:tokenCacheV2`); `plan-usage-history.json` = app tự ghi ~15 phút/lần
  `{t, org, u:{fh: % giới hạn 5 giờ, sd: % giới hạn 7 ngày}}` theo ORG (không theo tài khoản).
  ĐÃ DÙNG (23/10/2026): `Usage-ByAccount` -> `/api/sessions` trả `usage` (nhãn -> t, fh, sd, guess);
  giao diện hiện hàng "giới hạn" dưới tên tài khoản (quá 5 giờ / 7 ngày kể từ lúc ghi = "đã hồi").
  Org dùng chung nhiều tài khoản: gán theo `~/.claude/cs-account-log.json` (tool ghi tài khoản đang dùng
  theo `Active-Target` mỗi lần tải danh sách), chưa có thì đoán theo thẻ app tự ghi (`guess`, hiện dấu "?").

### Usage TRỰC TIẾP qua OAuth token người dùng tự dán (23/10/2026, sửa 24/10/2026)
Lý do: `Usage-ByAccount` ở trên chỉ mới khi app ghi mẫu (~15 phút/lần, CHỈ tài khoản đang đăng
nhập) → tài khoản khác luôn thấy số CŨ, không đúng ý người dùng ("bấm đồng bộ là có số mới của
mọi tài khoản"). Đã thử và loại các hướng khác trước khi chốt hướng này:
- Tool tự đọc token app giữ (`config.json`/`Local State`) → bị chặn cứng (xem ràng buộc 5).
- Tool tự đổi tài khoản lần lượt (như `Switch-Account`) để lấy số → người dùng từ chối (tắt app,
  nhấp nháy màn hình đăng nhập, không realtime).
- API chính thức của Anthropic (`api.anthropic.com`, Usage & Cost Admin API) → KHÁC sản phẩm, đo
  usage/cost gọi API bằng API key của tổ chức, không trả số % giới hạn 5 giờ/7 ngày của gói cá nhân.
- **23/10/2026, bỏ 24/10/2026**: cookie `sessionKey` dán vào `cookie.txt`, gọi
  `claude.ai/api/organizations/<orgId>/usage`. Người dùng báo "không còn đúng" (24/10/2026) → bỏ
  hẳn, thay bằng OAuth token dưới đây. (Code cũ: `Cookie-Path`/`Read-Cookie`/`Cookie-Accounts`/
  `Org-Of`/`Fetch-Usage-Live`/`Overlay-LiveUsage` — đã xoá khỏi `cs-gui.ps1`, đừng viết lại trừ khi
  cần so sánh.)

Cách làm (từ 24/10/2026, duy nhất còn dùng): NGƯỜI DÙNG tự lấy OAuth token của từng tài khoản (tự
chạy script riêng ngoài tool, vd đọc hồ sơ đã lưu ở `cs-profiles\<acct>\auth.json` qua
Switch-Account) rồi tự dán vào `~/.claude/cs-profiles\<mã tài khoản>\oauth-token.txt`. Tool CHỈ đọc
file text này — khác ràng buộc 5 vì đây là giá trị người dùng tự cung cấp, không phải tool tự lấy/
giải mã từ kho token của app.
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`, header `Authorization: Bearer
  <token>`. Không cần `orgId` (token gắn với tài khoản, không theo org).
- CHƯA XÁC NHẬN tên trường chính xác trong JSON trả về (chưa có mẫu thật). `Extract-Usage`/
  `Find-Pct` dò theo TỪ KHOÁ tên trường (`five_hour`/`seven_day`...), không hardcode đường dẫn cố
  định; dò không ra thì KHÔNG đoán bừa — giữ số cũ + tự ghi nguyên văn JSON vào
  `~/.claude/cs-usage-debug-<acct>.json` (chỉ ở máy người dùng) để xem và chỉnh `Extract-Usage` cho
  khớp khi có mẫu thật.
- Kết quả gộp vào `$usage` CÙNG hình dạng `{t, fh, sd, guess}` (thêm `live`/`tokenExpired`/
  `liveUnmapped`) nên UI (`usageBars`) dùng được luôn, không cần sửa cấu trúc hiển thị.
- `/api/sessions` gọi `Overlay-LiveUsage-OAuth` sau `Usage-ByAccount` — chạy mỗi lần tải danh
  sách/bấm nút ↻ hoặc Đồng bộ đã có sẵn, KHÔNG đổi tài khoản, KHÔNG tắt app. KHÔNG có nút riêng.
- AN TOÀN: không bao giờ in giá trị token ra chat/log.

**TỪ CHỐI 24/10/2026 — đừng thử lại:** người dùng yêu cầu tool TỰ chạy script trích token
(`get_desktop_token_profile.py`, đọc `cs-profiles\<acct>\auth.json`) mỗi lần bấm Đồng bộ, tự ghi
vào `oauth-token.txt`, rồi tự gọi usage — nghĩa là tool tự động hoá việc giải mã/trích token từ kho
lưu trữ app. Đã TỪ CHỐI: đúng loại hành động bị chặn ở ràng buộc 5 (đã thử 2 lần, bộ kiểm duyệt an
toàn chặn cứng vì "Credential Exploration", không lách được kể cả khi người dùng đồng ý). Giữ
nguyên ranh giới: bước trích token luôn do NGƯỜI DÙNG tự chạy script + tự dán vào `oauth-token.txt`;
tool chỉ được tự động hoá PHẦN SAU (đọc file text + gọi API usage), đã làm ở `Overlay-LiveUsage-OAuth`.
- **Đổi tài khoản không đăng nhập lại** (23/10/2026, người dùng đồng ý cho tool giữ đăng nhập; lần
  đầu bộ kiểm duyệt quyền của Claude Code chặn, sau khi người dùng xác nhận thì cho ghi):
  - Đăng nhập của app = khoá `oauth:*` + `lastKnownAccountUuid` + `bootSidebarPlaceholder`/`bootSideSessions`
    trong `config.json`, `Network\Cookies(-journal)`, `Local Storage`, `Session Storage`, `IndexedDB`.
    `Local State` (khoá giải mã) dùng chung => KHÔNG tráo. Tool chỉ chép file, không đọc/giải mã token.
  - Hồ sơ: `~/.claude/cs-profiles\<mã tài khoản>\` (+ `auth.json`, `saved.txt`; bản trước ở `.prev`).
  - `Switch-Account`: tắt app -> `Save-Profile` tài khoản hiện tại (chỉ khi còn token, không đè hồ sơ
    tốt bằng trạng thái đã đăng xuất) -> `Set-AuthState` hồ sơ đích (hoặc xoá = về màn đăng nhập,
    KHÔNG huỷ token phía máy chủ) -> mở app. Lỗi giữa chừng: mở lại app và báo.
  - API: `GET /api/accounts`, `POST /api/switch {acct}` (acct rỗng = đăng nhập tài khoản khác).
    Giao diện: nút "Tài khoản ▾" ở đầu trang.
  - Đã thử trên bản chép (token/cookie giả, `CS_DESKTOP_DIR`): cất/đổi qua lại/về màn đăng nhập đúng,
    khoá khác của config giữ nguyên.
  - Người dùng KHÔNG được bấm Đăng xuất trong app (huỷ token đã lưu). Giao diện có nhắc. Đã kiểm mã
    app: đăng xuất gọi máy chủ huỷ phiên (`[sessionKeyCookies] session revoked server-side`).
  - Thử thật 23/10/2026: "Đăng nhập tài khoản khác" + đăng nhập datpham559 chạy; 5c6bd36c thành "đã lưu".
  - DÍNH THẬT 23/10/2026: bấm "Vào" đổi sang tài khoản khác, `Save-Profile` báo lỗi `Exception
    calling "Move"... Access to the path 'cs-profiles\<acct>' is denied` — xảy ra ở bước đổi tên
    hồ sơ CŨ (`cs-profiles\<acct>` -> `.prev`), KHÔNG phải thư mục dữ liệu app. Kiểm tay ngay sau đó:
    tự đổi tên được thư mục đó bình thường (không khoá nữa), không có `.prev`/`.cs-tmp` sót lại (lỗi
    xảy ra trước khi đổi tên gì, không mất dữ liệu). `Wait-Closed` có chờ thêm 300ms sau khi tiến
    trình `claude` biến mất ("chờ Windows nhả hẳn file app vừa mở") nhưng không đủ ở lần đầu thử thật
    này — nghi do Windows Defender/antivirus quét các file vừa ghi trong `cs-profiles` (Cookies,
    IndexedDB...) giữ khoá vài giây. `Switch-Account` tự mở lại app khi lỗi giữa chừng (đúng thiết
    kế) nên không ảnh hưởng tài khoản đang dùng. ĐÃ SỬA: `Retry-FsOp` (thử lại tối đa 10 lần, cách
    300ms) bọc quanh mọi `Remove-Any`/`Copy-Any`/`[IO.Directory]::Move` trong `Save-Profile` và
    `Set-AuthState` — CHƯA kiểm lại trên app thật sau khi sửa.
  - BẮT BUỘC tắt app khi tráo: app giữ đăng nhập trong bộ nhớ, khoá file Cookies và ghi đè lại khi
    đang chạy. Tốc độ: `Desktop-Procs` từng duyệt mọi tiến trình (~1,5 s/lần, gọi nhiều lần mỗi lần
    đổi + mỗi lần mở menu) -> giờ `Get-Process -Name claude` (~30 ms); `Wait-Closed` dò 150 ms/lần.
  - `Active-Target` giờ lọc theo `lastKnownAccountUuid` (`$st.acctNow`).
  - Tên tài khoản: `config.json` không có email, nhưng trang claude.ai trong app cache tài khoản
    (`"uuid"…<mã>…"email_address"…<email>`) trong `IndexedDB\https_claude.ai_0.indexeddb.blob\…`.
    IndexedDB đi theo hồ sơ => `Learn-DesktopNames` (gọi trong `Account-Labels`) tìm email cho tài khoản
    đang dùng (thư mục app) + mọi hồ sơ đã lưu; chỉ điền tên trống/còn là mã (23/10/2026: học được
    5c6bd36c = eb12_claude). Nhớ file đã quét theo mtime (lần đầu ~0,25 s, sau ~8 ms). Vẫn còn nút
    "đổi tên" trong menu (`POST /api/account-name` -> `cs-accounts.txt`).
  - App KHÔNG phải lúc nào cũng ghi số giới hạn khi vào tài khoản (23/10/2026: vào eb11 ~30 giây, không
    có mẫu nào) => menu ghi "app chưa ghi số lần vào HH:mm" (`lastSeen` từ nhật ký tài khoản).
  - Giới hạn: đầu trang chỉ hiện tài khoản đang dùng (+ "số lúc HH:mm", nút ↻); tài khoản khác trong
    menu. Số chỉ mới khi app ghi (~15 phút) — ↻ không làm app ghi thêm. Gán số của org dùng chung: mục
    nhật ký ngay TRƯỚC lúc ghi số, không khớp org thì mục đầu tiên trong 2 phút SAU (app ghi số ngay
    lúc vừa đăng nhập, trước khi tool ghi nhật ký).
- Chưa từng dùng Claude Code trong app thì chưa có `claude-code-sessions` → nút Mở vẫn bắn deep link
  (app tự tạo thư mục), chỉ không chép sang tài khoản khác. Cửa sổ đen in thư mục Desktop đã dùng / đã tìm.
- **Cùng một session có thể mang tên thẻ khác nhau**: thẻ app tự tạo là `local_<uuid ngẫu nhiên>`;
  thẻ do deep link nhập là `local_<cliSessionId>`. => Tool nhóm/so khớp mọi thứ theo `cliSessionId`.
- **Cùng một mã session có thể có file chat ở 2 thư mục project** (20/10/2026 thấy 3 mã: bản ở thư mục
  chính + bản ở `.claude-worktrees-…` hoặc `scratch-workspaces`, cùng phần đầu lịch sử). `Scan-Sessions`
  gộp thành MỘT mục, file có mtime mới nhất là bản chính (cwd, tiêu đề, xem trước, ghép chuỗi). Trước
  đó danh sách hiện 2 dòng cùng mã, xem trước đọc nhầm file cũ hơn.
- `~/.claude.json` → `oauthAccount` là của Claude Code CLI, KHÔNG phải tài khoản Desktop đang dùng:
  app KHÔNG cập nhật khi đổi tài khoản (15/10/2026: app đã sang tài khoản khác, file vẫn ghi tài khoản cũ → tool cũ chép
  thẻ vào thẳng thư mục đang chạy, sinh 3 cặp trùng; đã dọn). Chỉ dùng nó để học tên uuid→email.
- Nhận ra tài khoản/org Desktop đang dùng (`Active-Target`): thẻ KHÔNG có `originAcct` được ghi gần
  nhất (app ghi thẻ mỗi lần bấm/dùng session và bỏ trường lạ khi lưu; thẻ tool chép luôn có
  `originAcct`). Hạn chế: vừa đổi tài khoản mà chưa bấm session nào thì còn đoán tài khoản cũ.
- **Vùng ảo hoá MSIX**: Claude Desktop (bản Store) ghi vào file chat đường dẫn ẢO
  `%APPDATA%\Claude\...` (thư mục `scratch-workspaces` của session không gắn project); thư mục thật ở
  `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\...` (hoặc `Claude-Data\<gói>\...` nếu app
  đã chuyển, xem trên). Tool chạy NGOÀI vùng ảo hoá → `Path-Exists` thử lần lượt mọi `Desktop-DataDirs`. Đã dính 16/10/2026: 7 session scratch bị báo "mất thư
  mục", khoá nút Mở và bị "Thêm tất cả" bỏ qua. LƯU Ý KHI KIỂM THỬ: phiên Claude Code chạy TRONG vùng
  ảo hoá (con của app) nên thấy cả hai đường dẫn đều "có" — phải kiểm từ ngoài (`explorer.exe <file.bat>`).
- Tiêu đề khi app nhập session CLI: app chỉ đọc bản ghi `{"type":"custom-title","customTitle":…}`
  trong đoạn CUỐI file chat (không đọc `ai-title`). Session terminal thường vào app không có tên.

## Deep link `claude://resume?session=<cliSessionId>` — thêm session KHÔNG cần restart
Tìm thấy khi đọc mã app (app.asar, bản 2.37337): `claudeURLHandler` → `case "resume"` →
`LocalSessionManager.importCliSession(cli)`. Đã kiểm chứng trên máy thật (14/10/2026):
- App đọc file chat, ghi thẻ `local_<cli>.json` vào **org đang đăng nhập**, đưa vào sidebar
  NGAY (danh sách trong bộ nhớ), rồi chuyển cửa sổ tới session đó. ~1,8 giây/session.
- Nếu tài khoản đã có session này (kể cả dưới tên thẻ khác) → app chỉ chuyển tới, **không tạo trùng**.
- Nhận cả session tạo từ terminal (chưa từng có thẻ). Tự tin cậy (trust) thư mục project.
- App đang tắt → deep link tự mở app rồi nhập (app nạp xong danh sách mới nhập).
- Tác dụng phụ: app "chạm" mtime file `.jsonl` (session nhảy lên đầu danh sách tool), thẻ mới có
  `createdAt` = lúc nhập, `adoptedFromOtherSurface: true`, `pendingSystemReminder`.
- Chỉ tác động tài khoản/org ĐANG ĐĂNG NHẬP. Tài khoản khác vẫn nhận bằng cách chép file thẻ;
  app đọc lại khi chuyển sang tài khoản đó (đổi tài khoản = app nạp lại danh sách).

## Chỉ còn bản PowerShell (từ 14/10/2026)
- Tool = `cs-gui.ps1` (PowerShell 5.1 + .NET có sẵn trong Windows 10/11, không cần cài gì, không cần
  admin) + `ui.html` (giao diện, server thay `__TOKEN__`) + `Kho session Claude.bat` (luôn chạy PS).
- Bản Node `cs-gui.js` ĐÃ BỎ (người dùng đồng ý sau khi bản PS được kiểm: mọi API đọc và mọi thao
  tác ghi cho kết quả giống hệt bản Node; deep link nhập/mở chạy trên app thật; mở lại app OK).
  Bản Node + bộ so sánh `dev-test/` nằm trong Thùng rác máy người dùng nếu cần đối chiếu. Đừng dựng
  lại bản Node trừ khi người dùng yêu cầu (lý do bỏ: phải bảo trì 2 bản; Node nặng để cài).
- Chưa chạy thật: nhánh TẮT app khi gỡ ở tài khoản đang đăng nhập (sẽ tắt luôn phiên Claude đang
  làm việc) — chỉ là `Stop-Process -Force` + `Wait-Closed`, cùng logic bản Node cũ.
- `.bat` tắt bản cũ trước khi chạy: tiến trình nghe cổng 4777 (bản Node đời trước) + powershell có
  `cs-gui.ps1` trong dòng lệnh (bản PS nghe qua http.sys = PID 4, không tắt theo cổng được).
- Cách thử thao tác ghi an toàn: chép thư mục thẻ ra thư mục tạm, chạy PS với `CS_DESKTOP_DIR=<bản
  chép>`, `USERPROFILE=<thư mục tạm>`, `CLAUDE_CONFIG_DIR=<~/.claude thật>`, `CS_PORT` khác, `CS_NO_BROWSER=1`
  → không thấy tài khoản đang đăng nhập (`/api/sync-all` GET trả `hot:false`) nên KHÔNG bắn deep
  link/không tắt app, sao lưu ghi vào thư mục tạm. LUÔN kiểm GET trước (hot phải false).
  Nạp hàm để thử riêng: `. .\cs-gui.ps1` (không chạy server).
- Bẫy PowerShell 5.1 đã dính (đừng lặp lại):
  - File `.ps1` PHẢI là UTF-8 có BOM (không thì tiếng Việt hỏng). File `.bat` để ASCII + CRLF.
  - Bí danh có sẵn được ưu tiên hơn hàm: hàm tên `LP` thực ra gọi `Out-Printer`. Đặt tên dạng
    Động-từ-Danh-từ dài; kiểm bằng `Get-Command <tên> -CommandType Alias,Cmdlet,Application`.
  - `$null` truyền vào tham số chuỗi của hàm .NET bị đổi thành `""` → dùng `[NullString]::Value`
    (vd `[IO.File]::Replace(tmp, dest, [NullString]::Value)`).
  - `return`/`$( )` tự "bóc" mảng 1 phần tử → `return ,$x`; tránh `$(if…)` cho danh sách.
  - Giới hạn đường dẫn 260 ký tự → hàm `Long-Path` thêm `\\?\`; `File.Replace` không nhận `\\?\`
    (dùng Copy đè); `Copy-Item -Recurse` hỏng với đường dẫn dài → `Copy-Tree` tự viết.
  - JSON: đọc/ghi thẻ bằng `JavaScriptSerializer` (đã thử 43/43 thẻ đọc-ghi lại giống hệt, không
    BOM). Phản hồi API dùng `To-JsonText` tự viết (serializer không nhận đối tượng PowerShell).
    TUYỆT ĐỐI không `ConvertTo-Json`.
  - Đọc file bằng FileShare ReadWrite|Delete (app/CLI đang ghi file chat).
  - Quét tiêu đề cả file chat: dùng `IndexOf` thường, KHÔNG regex (regex: 16 s → IndexOf: 2,5 s).
- Tốc độ tải danh sách (đo 14/10/2026, 31 file chat / 164 MB):
  - Cache kết quả quét lưu ở `~/.claude/cs-cache.json` (khoá = đường dẫn file chat, kèm mtime +
    kích thước; `exists` tính lại mỗi lần). Chỉ file chat đổi mới quét lại. Đổi cách tính trong
    `Parse-Session` thì TĂNG `$CacheVersion` để bỏ cache cũ.
  - Server quét sẵn TRƯỚC khi mở trình duyệt; giao diện hiện "Đang đọc danh sách session…".
  - Chỉ parse JSON dòng có thể cho thông tin còn thiếu (lọc trước bằng IndexOf); tiêu đề/tóm tắt
    duyệt NGƯỢC từ cuối file (bản mới nhất thắng) nên chỉ parse vài dòng.
  - Kết quả: chưa có cache 2,2 s → 1,4 s; có cache: quét lúc khởi động ~0,5 s, `/api/sessions` lần
    đầu ~0,4 s, sau đó ~0,13 s. Đã đối chiếu: 31/31 session cho kết quả giống hệt trước tối ưu.
  - HttpListener `http://127.0.0.1:<port>/` chạy được không cần admin (đã thử); http.sys tự chặn
    Host khác 127.0.0.1.
  - KHÔNG `Start-Process <url/exe>` thẳng: tiến trình con bám vào cửa sổ đen của tool → Claude
    (Electron/Chromium) in log "Unable to move the cache… Gpu Cache Creation failed" vào đó, và đóng
    cửa sổ tool có thể tắt luôn Claude vừa mở. Dùng `Open-Detached` (= `explorer.exe "<đích>"`) cho
    deep link, trình duyệt, mở app — đã kiểm: claude.exe nhận link có cha là explorer.exe.
  - Server một luồng (HttpListener): thao tác dài (Thêm tất cả ~2 s/session) chặn các yêu cầu khác
    tới khi xong — giao diện đã khoá nút trong lúc chạy.
- Chữ in ra cửa sổ đen để KHÔNG DẤU: font Raster mặc định của cửa sổ đen không có dấu tiếng Việt
  → hiện "?". Giao diện web vẫn có dấu.

## Tool (`cs-gui.ps1` + `ui.html`)
Giao diện web cục bộ `127.0.0.1:4777`, cố ý tối giản (người dùng yêu cầu "dễ dùng nhất"):
- Header: email đang đăng nhập · nút chính "Thêm tất cả session vào mọi tài khoản" · menu "⋯" (Gỡ tất cả
  khỏi tài khoản khác, Khởi động lại Claude Desktop — ít dùng nên giấu vào menu).
- Trái: ô tìm (tiêu đề + đường dẫn) + ô chọn tài khoản (mỗi mục ghi số session tài khoản đó ĐANG CÓ;
  tài khoản đang đăng nhập đứng đầu, ghi "· đang đăng nhập"; thêm mục "Chưa có trong app"). Chọn một
  tài khoản thì hiện 3 nút lọc kèm số đếm (thống kê): Tất cả / Tự tạo (origin = tài khoản đó) /
  Được thêm vào (có ở đó nhưng gốc ở tài khoản khác). Người dùng CẦN thống kê + lọc "chỉ do tài khoản
  này tạo" — đừng gộp mất lần nữa. Danh sách có badge tài khoản gốc.
- Phải: tiêu đề, đường dẫn, "Có ở: …", nút chính "Mở trong Claude Desktop",
  nút phụ "Gỡ khỏi N tài khoản khác" (chỉ hiện khi có), xem trước chat.
- Phạm vi phải LUÔN ghi rõ trên giao diện (người dùng từng hỏi "mở chỉ thêm tài khoản hiện tại hay
  tất cả? thêm tất cả là session đang chọn hay mọi session?"):
  - "Mở trong Claude Desktop" = CHỈ session đang chọn → tài khoản đang đăng nhập (hiện ngay) + chép
    sang tài khoản khác. Dòng gợi ý dưới nút (`openHint`) ghi tên tài khoản cụ thể.
  - "Thêm tất cả session vào mọi tài khoản" = MỌI session đã có thẻ trong Desktop (không gồm session
    "chưa có trong app"). Hộp xác nhận ghi tổng số, số thêm vào tài khoản đang đăng nhập, số chép và
    tên tài khoản nhận (`/api/sync-all` GET trả `total, links, copySessions, copyAccts, me`).
  - Thông báo đếm theo SESSION và TÊN TÀI KHOẢN (`opsSummary`), không nói "thẻ"/"org".
- Phím: ↑/↓ chọn, Enter/nhấp đúp = mở trong Desktop, `/` nhảy tới ô tìm, Esc đóng menu.
- ĐÃ BỎ (người dùng yêu cầu): "Mở trong terminal" (`/api/open`, `openTerminal`, `CS_TERMINAL`),
  ô LỌC theo project (ô tìm đã bao). Đừng thêm lại.
- Ô "Xếp" (23/10/2026, người dùng yêu cầu): "gần nhất" (mặc định) / "theo project" = nhóm có tiêu đề
  dính (sticky) + số đếm, nhóm có session mới nhất lên đầu. `groupOf`: mọi `scratch-workspaces\…` gom
  "Không gắn project"; worktree (`.claude\worktrees\…`, `.claude-worktrees-…`) tính vào project gốc.
  Nhớ lựa chọn bằng localStorage `cs-sort`. Tự tải lại: khi cửa sổ được focus + mỗi phút + nút ↻.
- Liệt kê mọi session (đọc `.jsonl`), tìm kiếm, xem trước.
- **Thêm tất cả vào mọi tài khoản** (`/api/sync-all`):
  - App đang chạy + biết org đang đăng nhập: session thiếu ở org đó → deep link lần lượt (hiện ngay);
    các org/tài khoản khác → chép file thẻ. KHÔNG ghi file vào org đang đăng nhập (app giữ trong
    bộ nhớ; file chép vào đó chỉ hiện sau restart và sẽ sinh trùng với thẻ deep link).
  - Sau pha deep link, quét lại: thư mục nào vừa xuất hiện `local_<cli>.json` cũng được coi là
    org đang hoạt động (phòng khi `Active-Target` đoán sai).
  - App tắt: chép file vào mọi org như cũ.
  - Bỏ qua: session đã xóa (`deleted_*`), mất `cwd`, đang lưu trữ (deep link sẽ bỏ lưu trữ).
- **Mở trong Claude Desktop** (`/api/open-desktop`): deep link nhập + mở session (kể cả session
  terminal), rồi chép thẻ sang tài khoản khác. Thẻ chép thiếu tiêu đề thì điền từ file chat.
- **Gỡ** (một/tất cả): xóa thẻ ở tài khoản không phải gốc. Thẻ ở tài khoản khác: xoá ngay.
  Thẻ ở tài khoản ĐANG ĐĂNG NHẬP (mọi org của nó, khi app đang chạy): chỉ xoá khi người dùng đồng ý
  khởi động lại — tool tắt app (Stop-Process -Force) → chờ tắt hẳn → xoá → mở lại. Nếu không đồng ý
  thì KHÔNG xoá thẻ đó (xoá lúc app chạy là vô ích, xem ràng buộc 8).
- **Khởi động lại Claude Desktop**: thường không cần nữa.
- Tự học tên tài khoản vào `~/.claude/cs-accounts.txt`; sao lưu `claude-code-sessions` vào
  `~/.claude/cs-backups` (giữ 5 bản) trước mỗi lần sửa; ghi `originAcct` vào thẻ chép.
- Đồng bộ thẻ cùng tên: chỉ ghi đè khi cũ hơn hoặc thiếu tiêu đề. Khác tên thẻ → để yên (tránh trùng).

## Ràng buộc đã kiểm chứng (ĐỪNG thử lại các cách đã hỏng)
1. App không tự nạp lại thẻ chép vào org đang đăng nhập. Đã thử, KHÔNG ăn: `Ctrl+R`; chạm
   `lastActivityAt`/`lastFocusedAt` (issue #78130). => Dùng deep link (ở trên), không chép file vào đó.
2. Ghi thẻ bằng `JavaScriptSerializer` (đọc-ghi lại giữ nguyên), KHÔNG dùng `ConvertTo-Json` (bẹp
   trường lồng nhau, thêm BOM → app bỏ qua thẻ).
3. Phải chép vào MỌI org của tài khoản.
4. Chỉ xử lý session còn `cwd` tồn tại.
5. Không tự động hoá đăng nhập / tráo token / đổi tài khoản. KHÔNG tự đọc/giải mã token hay cookie
   mà APP tự giữ (`config.json`, `Local State`, `Network\Cookies`, `cs-profiles\<acct>\auth.json`...)
   — đã thử 2 lần (23/10/2026) + từ chối lần 3 (24/10/2026, người dùng xin tool tự chạy script trích
   token mỗi lần Đồng bộ), bộ kiểm duyệt an toàn của Claude Code chặn cứng (lý do "Credential
   Exploration"), không lách được kể cả khi người dùng đồng ý + thêm quyền PowerShell vào
   `settings.local.json`. Khác với OAuth token ở mục "Usage trực tiếp qua OAuth token" bên dưới: đó
   là NGƯỜI DÙNG tự chạy công cụ của họ để lấy token rồi tự dán vào file riêng của tool
   (`cs-profiles\<acct>\oauth-token.txt`) — tool chỉ đọc file text đó, không đọc/chạy gì trên
   `auth.json` hay kho token/cookie của app.
6. Không ghi vào file chat `.jsonl` (dữ liệu gốc) — kể cả để thêm tiêu đề.
7. Đóng gói zip: KHÔNG dùng `ZipFile.CreateFromDirectory`/`Compress-Archive` của PS 5.1 (ghi đường
   dẫn bằng `\`). Dùng `dong-goi.ps1` (tạo từng mục, dấu `/`, mã UTF-8 — đã kiểm: cờ UTF-8 bật,
   giải nén ra đúng "HƯỚNG DẪN.txt").
8. KHÔNG có cách gỡ nóng session khỏi tài khoản đang đăng nhập (đã đọc mã app 2.37337): deep link
   chỉ có `resume` (nhập) và điều hướng; không có fs.watch trên thư mục thẻ; danh sách chỉ nạp lại
   khi khởi động/đổi tài khoản-org. Tệ hơn: xoá thẻ lúc app chạy thì app GHI LẠI thẻ khi session
   được bấm/focus (đã thấy: xoá 13:28:34, app ghi lại 13:28:40) → gỡ "không ăn" kể cả sau restart.
   `deleted_<id>` là bia mộ chống khôi phục, không phải kênh gỡ; tool không ghi bia mộ (sẽ chặn
   luôn việc Thêm lại). Ẩn ngay không restart chỉ làm được trong app: Lưu trữ (Archive) session.

## Rủi ro cần nhắc người dùng
- Session đã "thêm vào mọi tài khoản" thì AI đăng nhập tài khoản đó TRÊN MÁY NÀY đều đọc được.
- Tool dựa vào dữ liệu nội bộ + deep link không có tài liệu chính thức — bản cập nhật app có thể
  đổi. Kiểm tra lại `case "resume"` trong app.asar nếu deep link ngừng hoạt động.
- Pha deep link hàng loạt làm cửa sổ app chuyển qua từng session (~2 giây/session).

## Quy ước kỹ thuật
- `cs-gui.ps1` chỉ dùng PowerShell 5.1 + .NET có sẵn (không module/thư viện ngoài). Giao diện chỉ
  sửa trong `ui.html`.
- Server chỉ nhận Host `127.0.0.1:<port>`/`localhost:<port>` (chặn DNS rebinding) + header X-Token.
- Mọi đường dẫn lấy từ `USERPROFILE`/biến môi trường — không hardcode, để còn đóng gói.
- Ghi thẻ: không BOM, ghi `.cs-tmp` rồi thay thế (`Write-Atomic`).
- Biến môi trường: `CS_PORT`, `CS_DESKTOP_DIR`, `CLAUDE_CONFIG_DIR`, `CS_NO_BROWSER`.
- CSS có `[hidden]{display:none !important}` — vì `.head{display:flex}` từng đè thuộc tính `hidden`.
- Thư mục chỉ giữ bản đang dùng: `cs-gui.ps1`, `ui.html`, `Kho session Claude.bat`, `HƯỚNG DẪN.txt`
  (bản gốc của hướng dẫn trong zip), `dong-goi.ps1`, `Kho-session-Claude.zip`, `CLAUDE.md`.
  (14/10/2026 đã chuyển vào Thùng rác: bản Node `cs-gui.js`, `dev-test/`, `*.bak-truoc-deeplink`,
  `files.zip`, `cs-fix-origin.js`.)
- Gói gửi người khác = `Kho-session-Claude.zip` (.bat, cs-gui.ps1, ui.html, HƯỚNG DẪN.txt). Sửa xong
  thì chạy `dong-goi.ps1` để đóng gói lại. Không kèm CLAUDE.md. `.ps1`/`HƯỚNG DẪN.txt` có BOM.
