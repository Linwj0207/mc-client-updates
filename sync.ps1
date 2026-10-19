param([string]$ClientRoot = (Split-Path -Parent $PSScriptRoot), [switch]$Launch, [switch]$TestLocalhost)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$lockStream = $null
$journalPath = $null

function Read-Json([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Sha256([string]$Path) {
    $hash = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $hash.Dispose() }
}
function Write-Atomic([string]$Path, [string]$Text) {
    $temp = $Path + '.mcupdate-partial'
    [IO.File]::WriteAllText($temp, $Text, $utf8)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}
function Copy-Atomic([string]$Source, [string]$Destination) {
    $temp = $Destination + '.mcupdate-partial'
    [IO.File]::Copy($Source, $temp, $true)
    if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($temp, $Destination, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Destination) }
}
function Assert-Plain([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '更新目录或文件是链接，请让服主核对，暂不修改。'
        }
    }
}
function Assert-ModPath([string]$Path) {
    if ($Path -notmatch '^mods/[^<>:"/\\|?*\x00-\x1f]+\.jar$' -or $Path.Contains('..') -or $Path.Length -gt 190) {
        throw '清单含有不允许的模组路径。'
    }
    $name = $Path.Substring(5)
    if ($name -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])\.' -or $name -match '[ .]$') { throw '不支持的 Windows 文件名。' }
}
function Assert-Manifest($Manifest, [bool]$Remote) {
    if ($Manifest.schema -ne 1 -or @($Manifest.files).Count -lt 1 -or @($Manifest.files).Count -gt 1000) { throw '更新清单格式错误。' }
    $names = @{}
    foreach ($file in $Manifest.files) {
        Assert-ModPath $file.path
        if ($names.ContainsKey($file.path) -or $file.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $file.hash -notmatch '^[a-f0-9]{40}$' -or $file.size -lt 1 -or $file.size -ge 2147483648) { throw '模组清单缺少校验值或有重复文件。' }
        $names[$file.path] = $file
        if ($Remote) {
            if (@($file.downloads).Count -lt 1) { throw '模组缺少官方下载地址。' }
            foreach ($url in $file.downloads) { Assert-DownloadUrl $url }
        }
    }
    $addons = @{}
    foreach ($addon in $Manifest.addons) { $addons[$addon.id] = $addon.version }
    if ($addons.Count -ne 2 -or $addons.game -ne '1.21.1' -or $addons.neoforge -ne '21.1.226') {
        throw '本接入包不负责升级 Minecraft 或 NeoForge，请让服主制作匹配的新接入包。'
    }
    return $names
}
function Assert-DownloadUrl([string]$Url) {
    $uri = [Uri]$Url
    $allowed = @('cdn.modrinth.com', 'mediafilez.forgecdn.net', 'edge.forgecdn.net', 'maven.ftb.dev', 'github.com', 'raw.githubusercontent.com')
    $localTest = $TestLocalhost -and $uri.Scheme -eq 'http' -and $uri.Host -eq '127.0.0.1'
    if (-not $localTest -and ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $allowed -notcontains $uri.Host)) { throw '更新地址不属于允许的正式下载站点。' }
    if ($uri.UserInfo -or $uri.Fragment) { throw '不接受带登录资料的下载地址。' }
}
function Download([string]$Url, [string]$Destination) {
    Assert-DownloadUrl $Url
    $temp = $Destination + '.download-partial'
    Assert-Plain $temp
    try {
        Invoke-WebRequest -Uri $Url -OutFile $temp -UseBasicParsing -TimeoutSec 120 -Headers @{'Cache-Control'='no-cache'; 'User-Agent'='MC-Client-Sync/1.0'} | Out-Null
        if ([IO.File]::Exists($Destination)) { [IO.File]::Delete($Destination) }
        [IO.File]::Move($temp, $Destination)
    } catch {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        throw '下载未完成。请确认网络可访问 GitHub 和 Mod 官方下载站，稍后重新打开更新入口。'
    }
}
function Restore-Pending {
    if (-not [IO.File]::Exists($journalPath)) { return }
    $journal = Read-Json $journalPath
    if ($journal.schema -ne 1 -or $journal.backup -notmatch '^txn-[0-9a-f]{32}$') { throw '发现不能识别的更新记录，请联系服主。' }
    $savedRoot = Join-Path $runtime $journal.backup
    Assert-Plain $savedRoot
    foreach ($entry in $journal.entries) {
        $relative = [string]$entry.path
        if ($relative -ne 'modpack.cfg' -and $relative -ne '.mc-github-state.json') { Assert-ModPath $relative }
        $target = Join-Path $game $relative.Replace('/', '\')
        $saved = Join-Path $savedRoot $relative.Replace('/', '\')
        Assert-Plain $target
        Assert-Plain $saved
        if ($entry.existed) {
            if (-not [IO.File]::Exists($saved) -or (Sha256 $saved) -ne $entry.sha256) { throw '原文件备份校验失败，已停止恢复，请联系服主。' }
            Copy-Atomic $saved $target
        } elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
    }
    [IO.File]::Delete($journalPath)
    Write-Host '上次更新未完成，已恢复到更新前；现在重新检查。'
}

try {
    $settings = Read-Json (Join-Path $PSScriptRoot 'bootstrap.json')
    if (-not $settings.repository -or $settings.repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') {
        throw '服主尚未完成更新仓库设置，这个准备包暂不能使用。'
    }
    $client = (Resolve-Path -LiteralPath $ClientRoot).Path
    Assert-Plain $client
    foreach ($part in @('.minecraft', '.minecraft\versions', ('.minecraft\versions\' + $settings.version_id))) {
        Assert-Plain (Join-Path $client $part)
    }
    $game = Join-Path $client ('.minecraft\versions\' + $settings.version_id)
    $mods = Join-Path $game 'mods'
    if (-not (Test-Path -LiteralPath $mods -PathType Container)) { throw '请将接入包解压到原客户端根目录，与 HMCL 放在一起。' }
    Assert-Plain $mods
    $launcher = Join-Path $client $settings.launcher_name
    Assert-Plain $launcher
    if (-not [IO.File]::Exists($launcher) -or (Sha256 $launcher) -ne $settings.launcher_sha256) { throw '没有找到已验证的 HMCL-3.12.4.exe，请让服主补充。' }
    $versionSettings = Read-Json (Join-Path $game 'hmclversion.cfg')
    if ($versionSettings.gameDirType -ne 1 -or $versionSettings.gameDir) { throw '这个版本没有使用标准独立游戏目录，请让服主核对。' }
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(javaw?|HMCL.*)\.exe$' -and
        (($_.ExecutablePath -and $_.ExecutablePath.StartsWith($client, [StringComparison]::OrdinalIgnoreCase)) -or
         ($_.CommandLine -and $_.CommandLine.IndexOf($game, [StringComparison]::OrdinalIgnoreCase) -ge 0))
    })
    if ($running.Count) { throw '请先关闭这个客户端的游戏和 HMCL，再打开更新入口。' }
    $runtime = Join-Path $client '.mc-github-runtime'
    Assert-Plain $runtime
    [IO.Directory]::CreateDirectory($runtime) | Out-Null
    $lockPath = Join-Path $runtime 'update.lock'
    Assert-Plain $lockPath
    try { $lockStream = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw '另一个更新窗口正在运行，请等待它完成。' }
    $journalPath = Join-Path $runtime 'pending.json'
    Assert-Plain $journalPath
    Restore-Pending
    $cfgPath = Join-Path $game 'modpack.cfg'
    $statePath = Join-Path $game '.mc-github-state.json'
    Assert-Plain $cfgPath
    Assert-Plain $statePath
    $baseline = Read-Json (Join-Path $PSScriptRoot 'baseline.json')
    $baselineNames = Assert-Manifest $baseline $false
    if ([IO.File]::Exists($statePath)) {
        $state = Read-Json $statePath
        if ($state.repository -cne $settings.repository -or $state.version_id -cne $settings.version_id) { throw '此客户端已接入其他更新源，请联系服主。' }
        $previous = $state.manifest
        $previousNames = Assert-Manifest $previous $true
    } else {
        $previous = $baseline
        $previousNames = $baselineNames
        foreach ($path in $baselineNames.Keys) {
            $target = Join-Path $game $path.Replace('/', '\')
            Assert-Plain $target
            if ([IO.File]::Exists($target) -and (Sha256 $target) -ne $baselineNames[$path].sha256) {
                throw ('当前客户端不是原联机版本，暂不覆盖：' + $path)
            }
        }
        $extra = @(Get-ChildItem -LiteralPath $mods -File -Filter '*.jar' | Where-Object { -not $baselineNames.ContainsKey('mods/' + $_.Name) })
        if ($extra.Count) { throw '首次接入发现原清单以外的 Mod，请让服主核对；没有覆盖当前测试客户端。' }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $repo = [string]$settings.repository
    $base = 'https://raw.githubusercontent.com/' + $repo
    if ($TestLocalhost -and $settings.PSObject.Properties['test_base_url']) {
        Assert-DownloadUrl $settings.test_base_url
        $base = $settings.test_base_url
    }
    $channelPath = Join-Path $runtime 'channel.json'
    Assert-Plain $channelPath
    Download ($base + '/main/channel.json?t=' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')) $channelPath
    $channel = Read-Json $channelPath
    if ($channel.schema -ne 1 -or $channel.tag -notmatch '^[a-z0-9][a-z0-9._-]{0,79}$' -or
        $channel.manifest -cne ('manifests/' + $channel.tag + '.json') -or $channel.sha256 -notmatch '^[a-f0-9]{64}$') { throw '正式版本指向格式错误。' }
    $cache = Join-Path $runtime 'cache'
    Assert-Plain $cache
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $manifestDir = Join-Path $cache $channel.sha256
    Assert-Plain $manifestDir
    [IO.Directory]::CreateDirectory($manifestDir) | Out-Null
    $manifestPath = Join-Path $manifestDir 'manifest.json'
    Assert-Plain $manifestPath
    if (-not [IO.File]::Exists($manifestPath) -or (Sha256 $manifestPath) -ne $channel.sha256) {
        Download ($base + '/' + $channel.tag + '/' + $channel.manifest) $manifestPath
    }
    if ((Sha256 $manifestPath) -ne $channel.sha256) { throw '发布清单校验失败，未修改客户端。' }
    $next = Read-Json $manifestPath
    $nextNames = Assert-Manifest $next $true
    if ($next.id -cne $channel.tag) { throw '发布版本标识不一致。' }
    $changes = @{}
    foreach ($file in $next.files) {
        $target = Join-Path $game $file.path.Replace('/', '\')
        Assert-Plain $target
        if ([IO.File]::Exists($target) -and (Sha256 $target) -eq $file.sha256) { continue }
        if ([IO.File]::Exists($target) -and -not $previousNames.ContainsKey($file.path)) { throw ('新版本与自行安装的 Mod 同名，请联系服主：' + $file.path) }
        $cached = Join-Path $cache ($file.sha256 + '.jar')
        Assert-Plain $cached
        if (-not [IO.File]::Exists($cached) -or (Get-Item -LiteralPath $cached).Length -ne $file.size -or (Sha256 $cached) -ne $file.sha256) {
            Write-Host ('正在下载：' + $file.path.Substring(5))
            $downloaded = $false
            foreach ($url in $file.downloads) {
                try {
                    Download $url $cached
                    if ((Get-Item -LiteralPath $cached).Length -eq $file.size -and (Sha256 $cached) -eq $file.sha256) { $downloaded = $true; break }
                } catch { }
            }
            if (-not $downloaded) { throw ('Mod 下载失败或校验不符，未修改客户端：' + $file.path.Substring(5)) }
        }
        if ((Get-Item -LiteralPath $cached).Length -ne $file.size -or (Sha256 $cached) -ne $file.sha256) { throw 'Mod 下载校验失败，未修改客户端；下次打开会重新下载。' }
        $changes[$file.path] = $cached
    }
    foreach ($path in $previousNames.Keys) {
        if (-not $nextNames.ContainsKey($path)) {
            $target = Join-Path $game $path.Replace('/', '\')
            Assert-Plain $target
            if ([IO.File]::Exists($target)) { $changes[$path] = $null }
        }
    }
    # An empty fileApi makes HMCL's native Server task return without downloading.
    # The GitHub wrapper owns synchronization, including removal of retired mods.
    $hmclFiles = @($next.files | ForEach-Object { [ordered]@{path=$_.path; hash=$_.hash} })
    $cfg = [ordered]@{type='Server'; name=$next.name; version=$next.id; overrides=$hmclFiles;
        manifest=[ordered]@{name=$next.name; version=$next.id; author='MC project'; description='GitHub client update'; fileApi=''; files=$hmclFiles; addons=$next.addons}}
    $newState = [ordered]@{schema=1; repository=$repo; version_id=$settings.version_id; manifest=$next; manifest_sha256=$channel.sha256}
    $cfgText = $cfg | ConvertTo-Json -Depth 30
    $stateText = $newState | ConvertTo-Json -Depth 30
    $needsCommit = $changes.Count -gt 0 -or -not [IO.File]::Exists($statePath) -or
        ([IO.File]::ReadAllText($statePath) -cne $stateText) -or -not [IO.File]::Exists($cfgPath) -or ([IO.File]::ReadAllText($cfgPath) -cne $cfgText)
    if ($needsCommit) {
        $txnName = 'txn-' + [Guid]::NewGuid().ToString('N')
        $backup = Join-Path $runtime $txnName
        [IO.Directory]::CreateDirectory((Join-Path $backup 'mods')) | Out-Null
        $entries = @()
        foreach ($path in (@($changes.Keys) + @('modpack.cfg', '.mc-github-state.json'))) {
            $target = Join-Path $game $path.Replace('/', '\')
            $exists = [IO.File]::Exists($target)
            $hash = $null
            if ($exists) {
                $saved = Join-Path $backup $path.Replace('/', '\')
                [IO.File]::Copy($target, $saved, $false)
                $hash = Sha256 $saved
                if ((Sha256 $target) -ne $hash) { throw '更新前文件发生变化，已停止。' }
            }
            $entries += [ordered]@{path=$path; existed=$exists; sha256=$hash}
        }
        Write-Atomic $journalPath (([ordered]@{schema=1; backup=$txnName; entries=$entries}) | ConvertTo-Json -Depth 20)
        foreach ($path in $changes.Keys) {
            $target = Join-Path $game $path.Replace('/', '\')
            if ($changes[$path]) { Copy-Atomic $changes[$path] $target }
            else { [IO.File]::Delete($target) }
        }
        Write-Atomic $cfgPath $cfgText
        Write-Atomic $statePath $stateText
        [IO.File]::Delete($journalPath)
        Write-Host ('同步完成：' + $next.id + '，更新/移除 ' + $changes.Count + ' 个文件。旧文件保存在 .mc-github-runtime\' + $txnName)
    } else { Write-Host ('已经是正式版本：' + $next.id + '，无需下载。') }
    if ($Launch) { Start-Process -FilePath $launcher -WorkingDirectory $client | Out-Null }
} catch {
    $failure = $_.Exception.Message
    if ($journalPath -and [IO.File]::Exists($journalPath) -and $lockStream) {
        try { Restore-Pending } catch { $failure += '；恢复未完成：' + $_.Exception.Message }
    }
    Write-Host ('暂未启动游戏：' + $failure) -ForegroundColor Red
    exit 1
} finally { if ($lockStream) { $lockStream.Dispose() } }
