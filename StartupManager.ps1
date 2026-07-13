# StartupManager.ps1
# PC起動時に自動起動するソフト/アプリを一覧表示し、無効化・有効化・完全削除できるGUIツール。
# 対象: レジストリRunキー(HKCU/HKLM/32bit), スタートアップフォルダ(ユーザー/全ユーザー), ログオン/起動時タスク。
# 無効化は Windows のタスクマネージャーと同じ仕組み(StartupApproved)で行うため、いつでも元に戻せます。
#
# 使い方:
#   StartupManager.bat をダブルクリック (管理者昇格つきでGUIを起動)
#   powershell -ExecutionPolicy Bypass -File StartupManager.ps1 -List   (GUIなしで一覧表示)
#   powershell -ExecutionPolicy Bypass -File StartupManager.ps1 -Export items.csv   (CSV出力)

param(
    [switch]$List,
    [string]$Export,
    [switch]$Backup,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.10.0'

# ============================================================
# 共通設定
# ============================================================
$script:BackupRoot = Join-Path $PSScriptRoot 'Backups'
$script:LastBackupDir = $null
$script:MetaProps = @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')

$script:RunSources = @(
    @{ Name='レジストリ HKCU Run';        Run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';                         Approved='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Scope='User';    RegRoot='HKCU\Software\Microsoft\Windows\CurrentVersion\Run' }
    @{ Name='レジストリ HKLM Run';        Run='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';                         Approved='HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Scope='Machine'; RegRoot='HKLM\Software\Microsoft\Windows\CurrentVersion\Run' }
    @{ Name='レジストリ HKLM Run(32bit)'; Run='HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run';            Approved='HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Scope='Machine'; RegRoot='HKLM\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run' }
)

$script:FolderSources = @(
    @{ Name='スタートアップ(ユーザー)';   Path=[Environment]::GetFolderPath('Startup');       Approved='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope='User' }
    @{ Name='スタートアップ(全ユーザー)'; Path=[Environment]::GetFolderPath('CommonStartup'); Approved='HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope='Machine' }
)

# ストアアプリ(UWP)のスタートアップタスク。State: 0=無効,1=ユーザーが無効化,2=有効,3=ポリシーで無効,4=ポリシーで有効
$script:UwpRoot = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
$script:UwpNameCache = $null

# ============================================================
# StartupApproved (有効/無効) の読み書き
#   12バイトのバイナリ。先頭バイトが偶数(0x02/0x06)=有効, 奇数(0x03)=無効。
#   無効時は5バイト目以降に無効化した日時(FILETIME)が入る。
# ============================================================
function Get-ApprovedState {
    param($ApprovedKeyPath, $ValueName)
    # 戻り値: $true=有効, $false=無効, $null=エントリ無し(=既定で有効)
    try {
        $v = (Get-ItemProperty -Path $ApprovedKeyPath -Name $ValueName -ErrorAction Stop).$ValueName
        if ($v -is [byte[]] -and $v.Length -ge 1) {
            if (($v[0] -band 0x01) -eq 1) { return $false } else { return $true }
        }
        return $true
    } catch { return $null }
}

function New-ApprovedBytes {
    param([bool]$Enable)
    $b = New-Object byte[] 12
    if ($Enable) {
        $b[0] = 0x02
    } else {
        $b[0] = 0x03
        $ft = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
        [Array]::Copy($ft, 0, $b, 4, 8)
    }
    return ,$b
}

function Set-ApprovedState {
    param($ApprovedKeyPath, $ValueName, [bool]$Enable)
    if (-not (Test-Path $ApprovedKeyPath)) { New-Item -Path $ApprovedKeyPath -Force | Out-Null }
    $bytes = New-ApprovedBytes -Enable:$Enable
    New-ItemProperty -Path $ApprovedKeyPath -Name $ValueName -Value $bytes -PropertyType Binary -Force | Out-Null
}

function Get-DisabledDate {
    # 無効化された日時 (StartupApprovedの5バイト目以降のFILETIME) を返す。有効なら$null
    param($ApprovedKeyPath, $ValueName)
    try {
        $v = (Get-ItemProperty -Path $ApprovedKeyPath -Name $ValueName -ErrorAction Stop).$ValueName
        if ($v -is [byte[]] -and $v.Length -ge 12 -and (($v[0] -band 0x01) -eq 1)) {
            $ft = [BitConverter]::ToInt64($v, 4)
            if ($ft -gt 0) { return [DateTime]::FromFileTime($ft) }
        }
    } catch {}
    return $null
}

# ============================================================
# 起動項目の列挙
# ============================================================
function Get-RunItems {
    $result = @()
    foreach ($src in $script:RunSources) {
        if (-not (Test-Path $src.Run)) { continue }
        try { $props = Get-ItemProperty -Path $src.Run -ErrorAction Stop } catch { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($script:MetaProps -contains $p.Name) { continue }
            $state = Get-ApprovedState $src.Approved $p.Name
            $enabled = $true; if ($null -ne $state) { $enabled = $state }
            $result += [pscustomobject]@{
                Enabled=$enabled; Name=$p.Name; Type=$src.Name; Command=[string]$p.Value;
                Kind='Run'; RunPath=$src.Run; RegRoot=$src.RegRoot; ApprovedPath=$src.Approved; ValueName=$p.Name;
                Scope=$src.Scope; TaskName=''; TaskPath=''; FolderPath=''; FilePath=''
            }
        }
    }
    return $result
}

function Get-FolderItems {
    $result = @()
    $sh = $null
    try { $sh = New-Object -ComObject WScript.Shell } catch {}
    foreach ($src in $script:FolderSources) {
        if (-not $src.Path -or -not (Test-Path $src.Path)) { continue }
        $files = Get-ChildItem -Path $src.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }
        foreach ($f in $files) {
            $state = Get-ApprovedState $src.Approved $f.Name
            $enabled = $true; if ($null -ne $state) { $enabled = $state }
            $target = $f.FullName
            if ($f.Extension -eq '.lnk' -and $sh) {
                try { $target = ($sh.CreateShortcut($f.FullName)).TargetPath } catch {}
            }
            $result += [pscustomobject]@{
                Enabled=$enabled; Name=$f.Name; Type=$src.Name; Command=$target;
                Kind='Folder'; RunPath=''; RegRoot=''; ApprovedPath=$src.Approved; ValueName=$f.Name;
                Scope=$src.Scope; TaskName=''; TaskPath=''; FolderPath=$src.Path; FilePath=$f.FullName
            }
        }
    }
    return $result
}

function Get-LogonTaskItems {
    param([bool]$IncludeSystem)
    $result = @()
    try { $tasks = Get-ScheduledTask -ErrorAction Stop } catch { return $result }
    foreach ($t in $tasks) {
        $trigs = $t.Triggers
        if (-not $trigs) { continue }
        $isLogon = $false
        $trigNames = @()
        foreach ($tr in $trigs) {
            $cn = $null
            try { $cn = $tr.CimClass.CimClassName } catch {}
            if ($cn -eq 'MSFT_TaskLogonTrigger') { $isLogon = $true; $trigNames += 'ログオン時' }
            elseif ($cn -eq 'MSFT_TaskBootTrigger') { $isLogon = $true; $trigNames += 'システム起動時' }
        }
        if (-not $isLogon) { continue }
        if (-not $IncludeSystem -and $t.TaskPath -like '\Microsoft\*') { continue }
        $exec = ''
        try { $exec = (($t.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() }) -join ' | ') } catch {}
        $enabled = ($t.State -ne 'Disabled')
        $result += [pscustomobject]@{
            Enabled=$enabled; Name=$t.TaskName; Type='タスク(ログオン/起動)'; Command=$exec;
            Kind='Task'; RunPath=''; RegRoot=''; ApprovedPath=''; ValueName='';
            Scope='Machine'; TaskName=$t.TaskName; TaskPath=$t.TaskPath; FolderPath=''; FilePath='';
            TriggerInfo=(($trigNames | Select-Object -Unique) -join ', ')
        }
    }
    return $result
}

function Get-UwpItems {
    # ストアアプリ(UWP)のスタートアップタスク。タスクマネージャーの「スタートアップ アプリ」に出るものと同じ仕組み。
    $result = @()
    if (-not (Test-Path $script:UwpRoot)) { return $result }
    if ($null -eq $script:UwpNameCache) {
        $script:UwpNameCache = @{}
        try {
            foreach ($p in (Get-AppxPackage -ErrorAction Stop)) { $script:UwpNameCache[$p.PackageFamilyName] = $p.Name }
        } catch {}
    }
    foreach ($pfnKey in (Get-ChildItem -Path $script:UwpRoot -ErrorAction SilentlyContinue)) {
        foreach ($taskKey in (Get-ChildItem -Path $pfnKey.PSPath -ErrorAction SilentlyContinue)) {
            $state = $null
            try { $state = (Get-ItemProperty -Path $taskKey.PSPath -Name State -ErrorAction Stop).State } catch { continue }
            $pfn = $pfnKey.PSChildName
            $disp = if ($script:UwpNameCache.ContainsKey($pfn)) { $script:UwpNameCache[$pfn] } else { ($pfn -split '_')[0] }
            $result += [pscustomobject]@{
                Enabled=($state -eq 2 -or $state -eq 4); Name=($disp + ' (' + $taskKey.PSChildName + ')'); Type='ストアアプリ'; Command=$pfn;
                Kind='Uwp'; RunPath=''; RegRoot=''; ApprovedPath=''; ValueName='';
                Scope='User'; TaskName=''; TaskPath=''; FolderPath=''; FilePath=''; UwpKeyPath=[string]$taskKey.PSPath
            }
        }
    }
    return $result
}

function Get-AllStartupItems {
    param([bool]$IncludeSystemTasks)
    $all = @()
    $all += Get-RunItems
    $all += Get-FolderItems
    $all += Get-LogonTaskItems -IncludeSystem $IncludeSystemTasks
    $all += Get-UwpItems
    return $all
}

# 現在実行中のプロセスの実行ファイルパス一覧 (小文字キーのハッシュ)
function Get-RunningExeSet {
    $set = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.Path) { $set[$p.Path.ToLower()] = $true } } catch {}
    }
    return $set
}

# コマンド文字列から実行ファイルのフルパスを推定する ("C:\..\app.exe" --flag 等に対応)
function Get-ExecutablePath {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $c = $Command.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) {
            $p = $c.Substring(1, $end - 1)
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    if (Test-Path -LiteralPath $c) { return $c }
    # 引数付きの場合、スペース位置で区切りながら実在するパスを探す
    $idx = $c.Length
    while (($idx = $c.LastIndexOf(' ', $idx - 1)) -gt 0) {
        $p = $c.Substring(0, $idx).Trim('"')
        if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath $p -PathType Container)) { return $p }
    }
    return $null
}

# 項目の「起動場所」(どこに登録されているか) を人が読める文字列で返す
function Get-ItemLocation {
    param($Item)
    switch ($Item.Kind) {
        'Run'    { return $Item.RegRoot }
        'Folder' { return $Item.FolderPath }
        'Task'   { return ('タスク: ' + $Item.TaskPath + $Item.TaskName) }
        'Uwp'    { return 'ストアアプリ (AppModel/HKCU)' }
    }
    return ''
}

# Microsoft製 / Windows標準の項目かどうか (サードパーティ絞り込み用)。
# 発行元がMicrosoft、または実行ファイルがWindowsフォルダ配下なら「標準側」とみなす。
$script:WinDirLower = ([string]$env:SystemRoot).ToLower()
function Test-IsThirdParty {
    param($Item)
    if ($Item.Publisher -and ($Item.Publisher -match 'Microsoft')) { return $false }
    if ($Item.ExePath -and $Item.ExePath.ToLower().StartsWith($script:WinDirLower)) { return $false }
    # ストアアプリは発行元が空になりがちなので、パッケージ名/Microsoftの発行元ハッシュでも判定
    if ($Item.Kind -eq 'Uwp' -and $Item.Command -and ($Item.Command -match 'Microsoft|8wekyb3d8bbwe')) { return $false }
    return $true
}

# 「止める/消すと影響が出やすい」項目への、やさしい注意文を返す (該当しなければ空文字)。
# 断定せず「可能性があります」に留める — 迷ったら止める・分からないものは消さない、という方針に沿う。
function Get-SensitiveHint {
    param($Item)
    $hay = (([string]$Item.Name) + ' ' + ([string]$Item.Publisher) + ' ' + ([string]$Item.Command) + ' ' + ([string]$Item.ExePath)).ToLower()
    if ($hay -match 'defender|antivirus|eset|norton|mcafee|avast|\bavg\b|kaspersky|bitdefender|malwarebytes|trend ?micro|securityhealth|f-secure|sophos|webroot') {
        return 'セキュリティ対策ソフトの可能性があります。止めるとPCの保護が弱まる恐れがあります。'
    }
    if ($hay -match 'realtek|nvidia|\bamd\b|synaptics|\belan\b|touchpad|igfx|hdaudio|audio|soundblaster|logitech|\blogi\b|dolby|waves') {
        return 'ハードウェア(音声/画面/入力など)の常駐の可能性があります。止めると一部の機能が使えなくなることがあります。'
    }
    if ($hay -match 'onedrive|dropbox|google ?drive|googledrive|icloud|nextcloud|megasync|backup') {
        return 'クラウド同期/バックアップの可能性があります。止めると自動保存や同期が止まる場合があります。'
    }
    return ''
}

function Export-ItemsCsv {
    param($Items, [string]$Path)
    $Items | Sort-Object Kind, Type, Name | Select-Object `
        @{N='状態';   E={ if ($_.Enabled) { '有効' } else { '無効' } }},
        @{N='名前';   E={ $_.Name }},
        @{N='種類';   E={ $_.Type }},
        @{N='起動場所'; E={ Get-ItemLocation $_ }},
        @{N='コマンド'; E={ $_.Command }},
        @{N='範囲';   E={ $_.Scope }},
        @{N='分類';   E={ $_.Kind }} |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

# ============================================================
# バックアップ (削除前の保険)
# ============================================================
function New-FullBackup {
    if (-not (Test-Path $script:BackupRoot)) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null }
    $ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $script:BackupRoot $ts
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $regTargets = @(
        @{ Key='HKCU\Software\Microsoft\Windows\CurrentVersion\Run';                          File='HKCU_Run.reg' }
        @{ Key='HKLM\Software\Microsoft\Windows\CurrentVersion\Run';                          File='HKLM_Run.reg' }
        @{ Key='HKLM\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run';              File='HKLM_Run32.reg' }
        @{ Key='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved';     File='HKCU_StartupApproved.reg' }
        @{ Key='HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved';     File='HKLM_StartupApproved.reg' }
    )
    foreach ($rt in $regTargets) {
        try { & reg.exe export $rt.Key (Join-Path $dir $rt.File) /y *> $null } catch {}
    }

    foreach ($src in $script:FolderSources) {
        if ($src.Path -and (Test-Path $src.Path)) {
            $sub = Join-Path $dir ($src.Scope + '_StartupFolder')
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            Get-ChildItem -Path $src.Path -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'desktop.ini' } |
                ForEach-Object { Copy-Item $_.FullName -Destination $sub -Force -ErrorAction SilentlyContinue }
        }
    }
    return $dir
}

# バックアップフォルダの内容を現在の環境に書き戻す
function Restore-FromBackup {
    param([string]$Dir)
    $log = @()
    # レジストリ (.reg)
    foreach ($f in (Get-ChildItem -Path $Dir -Filter '*.reg' -File -ErrorAction SilentlyContinue)) {
        $p = Start-Process reg.exe -ArgumentList 'import', ('"' + $f.FullName + '"') -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0) { $log += "OK: $($f.Name)" }
        else { $log += "失敗: $($f.Name) (HKLM側は管理者権限が必要です)" }
    }
    # スタートアップフォルダ
    $map = @{
        'User_StartupFolder'    = [Environment]::GetFolderPath('Startup')
        'Machine_StartupFolder' = [Environment]::GetFolderPath('CommonStartup')
    }
    foreach ($k in $map.Keys) {
        $src = Join-Path $Dir $k
        if (-not (Test-Path $src) -or -not $map[$k]) { continue }
        foreach ($f in (Get-ChildItem -Path $src -File -ErrorAction SilentlyContinue)) {
            try { Copy-Item -LiteralPath $f.FullName -Destination $map[$k] -Force; $log += "OK: $k\$($f.Name)" }
            catch { $log += "失敗: $($f.Name) : $($_.Exception.Message)" }
        }
    }
    # タスク (削除時に書き出したXML)。隣の .meta から元のTaskName/TaskPathを復元する
    foreach ($f in (Get-ChildItem -Path $Dir -Filter 'task_*.xml' -File -ErrorAction SilentlyContinue)) {
        $name = $f.BaseName.Substring(5)
        $taskPath = '\'
        $meta = [System.IO.Path]::ChangeExtension($f.FullName, '.meta')
        if (Test-Path -LiteralPath $meta) {
            try {
                $lines = Get-Content -LiteralPath $meta -ErrorAction Stop
                if ($lines.Count -ge 1 -and $lines[0]) { $name = $lines[0] }
                if ($lines.Count -ge 2 -and $lines[1]) { $taskPath = $lines[1] }
            } catch {}
        }
        try {
            Register-ScheduledTask -TaskName $name -TaskPath $taskPath -Xml (Get-Content -LiteralPath $f.FullName -Raw) -Force | Out-Null
            $log += "OK: タスク $taskPath$name"
        } catch { $log += "失敗: タスク $name : $($_.Exception.Message)" }
    }
    if ($log.Count -eq 0) { $log = @('復元対象が見つかりませんでした。') }
    return $log
}

# ============================================================
# 状態変更 / 削除
# ============================================================
function Set-ItemState {
    param($Item, [bool]$Enable)
    switch ($Item.Kind) {
        'Run'    { Set-ApprovedState $Item.ApprovedPath $Item.ValueName $Enable }
        'Folder' { Set-ApprovedState $Item.ApprovedPath $Item.ValueName $Enable }
        'Task'   {
            if ($Enable) { Enable-ScheduledTask  -TaskName $Item.TaskName -TaskPath $Item.TaskPath | Out-Null }
            else         { Disable-ScheduledTask -TaskName $Item.TaskName -TaskPath $Item.TaskPath | Out-Null }
        }
        'Uwp'    {
            $v = if ($Enable) { 2 } else { 1 }
            New-ItemProperty -Path $Item.UwpKeyPath -Name State -Value $v -PropertyType DWord -Force | Out-Null
        }
    }
}

# レジストリ値が存在する場合のみ削除する。アクセス拒否など本当のエラーは呼び出し元へ伝える
function Remove-RegValueIfPresent {
    param($Path, $Name)
    $exists = $false
    try { $exists = $null -ne (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $exists = $false }
    if ($exists) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction Stop }
}

function Remove-ItemHard {
    param($Item, $BackupDir)
    switch ($Item.Kind) {
        'Run' {
            # 値の削除は -ErrorAction Stop。権限不足などは例外として呼び出し元(Invoke-OnSelection)が集計する
            Remove-ItemProperty -Path $Item.RunPath -Name $Item.ValueName -ErrorAction Stop
            Remove-RegValueIfPresent $Item.ApprovedPath $Item.ValueName
        }
        'Folder' {
            if (Test-Path -LiteralPath $Item.FilePath) {
                # バックアップ側へ退避 (これ自体が失敗したら削除もしない=データを守る)
                Move-Item -LiteralPath $Item.FilePath -Destination (Join-Path $BackupDir ('removed_' + $Item.ValueName)) -Force -ErrorAction Stop
            }
            Remove-RegValueIfPresent $Item.ApprovedPath $Item.ValueName
        }
        'Task' {
            # ファイル名を TaskPath 込みで一意化し、元の TaskName/TaskPath を .meta に保存 (正確な復元のため)
            $full = ($Item.TaskPath + $Item.TaskName).TrimStart('\')
            $safe = ($full -replace '[\\/:*?"<>|]', '_')
            $base = Join-Path $BackupDir ('task_' + $safe)
            $xmlPath = $base + '.xml'
            $n = 1
            while (Test-Path -LiteralPath $xmlPath) { $xmlPath = $base + "_$n.xml"; $n++ }
            try {
                Export-ScheduledTask -TaskName $Item.TaskName -TaskPath $Item.TaskPath | Out-File $xmlPath -Encoding utf8
                ($Item.TaskName, $Item.TaskPath) | Set-Content -LiteralPath ([System.IO.Path]::ChangeExtension($xmlPath, '.meta')) -Encoding UTF8
            } catch {}
            Unregister-ScheduledTask -TaskName $Item.TaskName -TaskPath $Item.TaskPath -Confirm:$false
        }
        'Uwp' {
            throw 'ストアアプリの起動項目は削除できません。「無効化」を使うか、アプリ自体をアンインストールしてください。'
        }
    }
}

# ============================================================
# CLIモード (-List: 一覧表示 / -Export: CSV出力。GUIを開かない)
# ============================================================
if ($List) {
    $items = Get-AllStartupItems -IncludeSystemTasks $false
    $items | Sort-Object Kind, Type, Name |
        Format-Table @{L='状態';E={ if($_.Enabled){'有効'}else{'無効'} }}, Name, Type, @{L='コマンド';E={ $_.Command }} -AutoSize | Out-String -Width 4000 | Write-Output
    Write-Output ("--- 合計 {0} 件 (Run/フォルダ/タスク/ストアアプリ, システムタスク除く) ---" -f $items.Count)
    return
}

if ($Export) {
    $items = Get-AllStartupItems -IncludeSystemTasks $false
    Export-ItemsCsv -Items $items -Path $Export
    Write-Output ("{0} 件を書き出しました: {1}" -f $items.Count, (Resolve-Path $Export).Path)
    return
}

if ($Backup) {
    $dir = New-FullBackup
    Write-Output ("バックアップを作成しました: {0}" -f $dir)
    return
}

# ============================================================
# -SelfTest: コア機能の動作テスト
#   HKCUにダミー項目を作成し、列挙 → 無効化 → 再有効化 → 後片付け を検証。
#   実在の起動項目には一切触れない。
# ============================================================
if ($SelfTest) {
    $script:fails = 0
    function Assert { param($Cond, $Label)
        if ($Cond) { Write-Output "PASS: $Label" } else { Write-Output "FAIL: $Label"; $script:fails++ }
    }
    Write-Output "== StartupManager v$($script:Version) セルフテスト =="
    $name = 'ZZZ_StartupManager_SelfTest'
    $runKey = $script:RunSources[0].Run          # HKCU Run
    $approvedKey = $script:RunSources[0].Approved
    try {
        New-ItemProperty -Path $runKey -Name $name -Value '"C:\Windows\System32\cmd.exe" /c exit' -PropertyType String -Force | Out-Null
        $it = @(Get-RunItems) | Where-Object { $_.Name -eq $name }
        Assert ($null -ne $it) '登録した項目が列挙される'
        Assert ($it.Enabled) '初期状態は有効と判定される'
        Assert ((Get-ItemLocation $it) -eq $script:RunSources[0].RegRoot) '起動場所が正しく表示される'

        Set-ApprovedState $approvedKey $name $false
        Assert ((Get-ApprovedState $approvedKey $name) -eq $false) '無効化がStartupApprovedに反映される'
        $it2 = @(Get-RunItems) | Where-Object { $_.Name -eq $name }
        Assert (-not $it2.Enabled) '列挙結果にも無効が反映される'
        Assert ($null -ne (Get-DisabledDate $approvedKey $name)) '無効化日時が記録される'

        Set-ApprovedState $approvedKey $name $true
        Assert ((Get-ApprovedState $approvedKey $name) -eq $true) '再有効化が反映される'
    } finally {
        Remove-ItemProperty -Path $runKey      -Name $name -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $approvedKey -Name $name -ErrorAction SilentlyContinue
    }
    Assert ($null -eq (@(Get-RunItems) | Where-Object { $_.Name -eq $name })) 'テスト項目が後片付けされた'

    Assert ((Get-ExecutablePath '"C:\Windows\System32\cmd.exe" /c exit') -eq 'C:\Windows\System32\cmd.exe') 'パス解決: 引用符+引数'
    Assert ((Get-ExecutablePath 'C:\Windows\System32\cmd.exe') -eq 'C:\Windows\System32\cmd.exe') 'パス解決: 素のパス'
    Assert ((Get-ExecutablePath 'C:\Windows\System32\cmd.exe /c exit') -eq 'C:\Windows\System32\cmd.exe') 'パス解決: 引用符なし+引数'
    Assert ($null -eq (Get-ExecutablePath 'C:\存在しないフォルダ\nothing.exe --x')) 'パス解決: 存在しないパスはnull'

    $bk = New-FullBackup
    Assert ((Test-Path (Join-Path $bk 'HKCU_Run.reg'))) 'バックアップにHKCU_Run.regが含まれる'
    Assert ((Test-Path (Join-Path $bk 'HKCU_StartupApproved.reg'))) 'バックアップにStartupApprovedが含まれる'
    Remove-Item -Path $bk -Recurse -Force -ErrorAction SilentlyContinue   # テストで作ったバックアップは削除

    # スタートアップフォルダ項目の列挙と無効化
    $folderSrc = $script:FolderSources[0]
    $testFileName = 'ZZZ_SM_SelfTest.txt'
    $testFile = Join-Path $folderSrc.Path $testFileName
    try {
        if (-not (Test-Path $folderSrc.Path)) { New-Item -ItemType Directory -Path $folderSrc.Path -Force | Out-Null }
        Set-Content -LiteralPath $testFile -Value 'selftest'
        $fi = @(Get-FolderItems) | Where-Object { $_.Name -eq $testFileName }
        Assert ($null -ne $fi) 'スタートアップフォルダの項目が列挙される'
        Set-ApprovedState $folderSrc.Approved $testFileName $false
        $fi2 = @(Get-FolderItems) | Where-Object { $_.Name -eq $testFileName }
        Assert (-not $fi2.Enabled) 'フォルダ項目の無効化が反映される'
    } finally {
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $folderSrc.Approved -Name $testFileName -ErrorAction SilentlyContinue
    }

    # 完全削除 → バックアップから復元 の往復 (エンドツーエンド)
    $name2 = 'ZZZ_StartupManager_SelfTest2'
    $bk2 = $null
    try {
        New-ItemProperty -Path $runKey -Name $name2 -Value '"C:\Windows\System32\cmd.exe" /c exit' -PropertyType String -Force | Out-Null
        $bk2 = New-FullBackup
        $it3 = @(Get-RunItems) | Where-Object { $_.Name -eq $name2 }
        Remove-ItemHard -Item $it3 -BackupDir $bk2
        Assert ($null -eq (@(Get-RunItems) | Where-Object { $_.Name -eq $name2 })) '完全削除で項目が消える'
        Restore-FromBackup -Dir $bk2 | Out-Null
        Assert ($null -ne (@(Get-RunItems) | Where-Object { $_.Name -eq $name2 })) 'バックアップからの復元で項目が戻る'
    } finally {
        Remove-ItemProperty -Path $runKey      -Name $name2 -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $approvedKey -Name $name2 -ErrorAction SilentlyContinue
        if ($bk2) { Remove-Item -Path $bk2 -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # CSVエクスポート
    $csvTmp = Join-Path $env:TEMP 'StartupManager_SelfTest.csv'
    try {
        Export-ItemsCsv -Items (Get-AllStartupItems -IncludeSystemTasks $false) -Path $csvTmp
        Assert ((Test-Path $csvTmp) -and ((Get-Content $csvTmp -TotalCount 1) -match '名前')) 'CSVエクスポートが動作する'
    } finally { Remove-Item -Path $csvTmp -Force -ErrorAction SilentlyContinue }

    # サードパーティ判定
    $msItem   = [pscustomobject]@{ Publisher='Microsoft Corporation'; ExePath='C:\Windows\System32\a.exe' }
    $winItem  = [pscustomobject]@{ Publisher='';                      ExePath=(Join-Path $env:SystemRoot 'x.exe') }
    $thirdItem= [pscustomobject]@{ Publisher='Acme Inc.';             ExePath='C:\Program Files\Acme\app.exe' }
    $uwpMs    = [pscustomobject]@{ Kind='Uwp'; Command='Microsoft.WindowsTerminal_8wekyb3d8bbwe'; Publisher=''; ExePath=$null }
    Assert (-not (Test-IsThirdParty $msItem))   'Microsoft発行元は標準側と判定'
    Assert (-not (Test-IsThirdParty $winItem))  'Windowsフォルダ配下は標準側と判定'
    Assert (-not (Test-IsThirdParty $uwpMs))    'Microsoftストアアプリはパッケージ名で標準側と判定'
    Assert (Test-IsThirdParty $thirdItem)       'サードパーティ製は第三者と判定'

    # 重要そうな項目の注意判定
    Assert ((Get-SensitiveHint ([pscustomobject]@{ Name='SecurityHealth'; Publisher='Microsoft'; Command=''; ExePath='' }))    -match 'セキュリティ') 'セキュリティ項目を検出'
    Assert ((Get-SensitiveHint ([pscustomobject]@{ Name='RtkAudUService'; Publisher='Realtek'; Command=''; ExePath='' }))       -match 'ハードウェア') 'ドライバー項目を検出'
    Assert ((Get-SensitiveHint ([pscustomobject]@{ Name='OneDrive'; Publisher='Microsoft'; Command=''; ExePath='onedrive.exe' })) -match '同期|バックアップ') 'クラウド同期項目を検出'
    Assert ((Get-SensitiveHint ([pscustomobject]@{ Name='Acme'; Publisher='Acme'; Command='app.exe'; ExePath='app.exe' }))       -eq '')            '無関係な項目には注意を出さない'

    # ストアアプリ(UWP)の列挙 (実項目には触れない)
    $uwOk = $true
    try { $null = @(Get-UwpItems) } catch { $uwOk = $false }
    Assert $uwOk 'ストアアプリの列挙がエラーなく動作する'

    # ストアアプリの状態切替は、実在アプリではなく専用のダミーキーで検証する
    $uwpPkg  = Join-Path $script:UwpRoot 'ZZZ_SM_SelfTest_pkg'
    $uwpTest = Join-Path $uwpPkg 'ZZZ_SM_SelfTest_task'
    try {
        New-Item -Path $uwpTest -Force | Out-Null
        New-ItemProperty -Path $uwpTest -Name State -Value 2 -PropertyType DWord -Force | Out-Null
        $dummy = [pscustomobject]@{ Kind='Uwp'; UwpKeyPath=$uwpTest }
        Set-ItemState -Item $dummy -Enable $false
        Assert ((Get-ItemProperty -Path $uwpTest -Name State).State -eq 1) 'ストアアプリの無効化(State=1)が書き込める'
        Set-ItemState -Item $dummy -Enable $true
        Assert ((Get-ItemProperty -Path $uwpTest -Name State).State -eq 2) 'ストアアプリの有効化(State=2)が書き込める'
    } catch {
        Assert $false ("ストアアプリの状態切替テスト: " + $_.Exception.Message)
    } finally {
        Remove-Item -Path $uwpPkg -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 実行中プロセスの検出
    $running = Get-RunningExeSet
    $me = $null
    try { $me = (Get-Process -Id $PID).Path } catch {}
    Assert ($running.Count -gt 0 -and $me -and $running.ContainsKey($me.ToLower())) '実行中プロセスの検出が動作する'

    if ($script:fails -eq 0) { Write-Output '== 全テスト合格 ==' }
    else { Write-Output ("== {0} 件失敗 ==" -f $script:fails); exit 1 }
    return
}

# ============================================================
# GUI
# ============================================================
# コンソールウィンドウを隠す
try {
    $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);'
    $win = Add-Type -MemberDefinition $sig -Name Win -Namespace NativeSM -PassThru
    $win::ShowWindow($win::GetConsoleWindow(), 0) | Out-Null
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 多重起動防止
$script:Mutex = New-Object System.Threading.Mutex($false, 'StartupManagerGUI_SingleInstance')
$owned = $false
try { $owned = $script:Mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    [System.Windows.Forms.MessageBox]::Show('StartupManager はすでに起動しています。', 'StartupManager') | Out-Null
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

$form = New-Object System.Windows.Forms.Form
$form.Text = "StartupManager v$($script:Version) - 起動時に自動起動するソフトの管理"
$form.Size = New-Object System.Drawing.Size(1000, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(920, 480)
try { $form.Font = New-Object System.Drawing.Font('Meiryo UI', 9) } catch {}

# --- 設定の読み込み (ウィンドウサイズ / システムタスク表示) ---
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:Settings = $null
try {
    if (Test-Path $script:SettingsFile) { $script:Settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json }
} catch {}
if ($script:Settings) {
    try {
        if ([int]$script:Settings.Width -ge 920 -and [int]$script:Settings.Height -ge 480) {
            $form.Size = New-Object System.Drawing.Size([int]$script:Settings.Width, [int]$script:Settings.Height)
        }
    } catch {}
}
$form.Add_FormClosing({
    try {
        $w = $form.Width; $h = $form.Height
        if ($form.WindowState -ne 'Normal') { $w = $form.RestoreBounds.Width; $h = $form.RestoreBounds.Height }
        @{ Width = $w; Height = $h; ShowSystemTasks = [bool]$chkSystem.Checked; ThirdPartyOnly = [bool]$chkThirdParty.Checked } |
            ConvertTo-Json | Set-Content -Path $script:SettingsFile -Encoding UTF8
    } catch {}
})

# --- 上部: 検索 / オプション ---
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = '絞り込み:'
$lblSearch.Location = New-Object System.Drawing.Point(12, 15)
$lblSearch.AutoSize = $true
$form.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(72, 12)
$txtSearch.Size = New-Object System.Drawing.Size(210, 24)
$txtSearch.Anchor = 'Top,Left'
$form.Controls.Add($txtSearch)

# サードパーティ製のみ表示 (Microsoft/Windows標準を隠す)。起動を軽くする掃除に便利
$chkThirdParty = New-Object System.Windows.Forms.CheckBox
$chkThirdParty.Text = 'サードパーティのみ'
$chkThirdParty.Location = New-Object System.Drawing.Point(292, 14)
$chkThirdParty.AutoSize = $true
if ($script:Settings -and $script:Settings.ThirdPartyOnly) { $chkThirdParty.Checked = $true }
$form.Controls.Add($chkThirdParty)

$chkSystem = New-Object System.Windows.Forms.CheckBox
$chkSystem.Text = 'システムのタスクも表示'
$chkSystem.Location = New-Object System.Drawing.Point(440, 14)
$chkSystem.AutoSize = $true
if ($script:Settings -and $script:Settings.ShowSystemTasks) { $chkSystem.Checked = $true }  # イベント登録前なので再列挙は走らない
$form.Controls.Add($chkSystem)

$lblAdmin = New-Object System.Windows.Forms.Label
$lblAdmin.AutoSize = $true
$lblAdmin.Location = New-Object System.Drawing.Point(660, 15)
if ($isAdmin) { $lblAdmin.Text = '管理者: 有効'; $lblAdmin.ForeColor = [System.Drawing.Color]::Green }
else          { $lblAdmin.Text = '管理者: 無効'; $lblAdmin.ForeColor = [System.Drawing.Color]::Firebrick }
$lblAdmin.Anchor = 'Top,Right'
$form.Controls.Add($lblAdmin)

# 非管理者のときはワンクリックで昇格再起動できるリンクを出す
if (-not $isAdmin) {
    $lnkAdmin = New-Object System.Windows.Forms.LinkLabel
    $lnkAdmin.Text = '管理者として再起動'
    $lnkAdmin.AutoSize = $true
    $lnkAdmin.Location = New-Object System.Drawing.Point(760, 15)
    $lnkAdmin.Anchor = 'Top,Right'
    $lnkAdmin.Add_LinkClicked({
        try {
            try { $script:Mutex.ReleaseMutex() } catch {}
            Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"') -Verb RunAs
            $form.Close()
        } catch {}   # UACキャンセル時は何もしない
    })
    $form.Controls.Add($lnkAdmin)
}

# --- 一覧 ---
$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(12, 45)
$lv.Size = New-Object System.Drawing.Size(960, 455)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.MultiSelect = $true
$lv.Anchor = 'Top,Bottom,Left,Right'
[void]$lv.Columns.Add('状態', 60)
[void]$lv.Columns.Add('名前', 200)
[void]$lv.Columns.Add('種類', 140)
[void]$lv.Columns.Add('発行元', 130)
[void]$lv.Columns.Add('起動場所', 200)
[void]$lv.Columns.Add('コマンド / パス', 250)
$lv.ShowItemToolTips = $true
# ちらつき防止 (DoubleBufferedはprotectedなのでリフレクションで設定)
try {
    $lv.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($lv, $true, $null)
} catch {}
# 実行ファイルのアイコン表示
$imgList = New-Object System.Windows.Forms.ImageList
$imgList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$imgList.ImageSize = New-Object System.Drawing.Size(16, 16)
$lv.SmallImageList = $imgList
$form.Controls.Add($lv)

# 列クリックソートの状態 (-1 = 既定ソート: 無効を先頭 → 分類 → 名前)
$script:SortColumn = -1
$script:SortAsc = $true

# --- 下部ボタン ---
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Location = New-Object System.Drawing.Point(12, 508)
$panel.Size = New-Object System.Drawing.Size(960, 40)
$panel.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($panel)

function New-Btn($text, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = $w
    $b.Height = 34
    $b.Margin = New-Object System.Windows.Forms.Padding(0,0,8,0)
    return $b
}
$btnRefresh = New-Btn '更新' 70
$btnAdd     = New-Btn '新規追加' 90
$btnEnable  = New-Btn '有効化' 80
$btnDisable = New-Btn '無効化' 80
$btnRemove  = New-Btn '完全削除' 90
$btnBackup  = New-Btn 'バックアップ作成' 130
$btnRestore = New-Btn '復元...' 70
$btnOpen    = New-Btn '保存場所を開く' 115
$btnCsv     = New-Btn 'CSV出力' 80
$panel.Controls.AddRange(@($btnRefresh,$btnAdd,$btnEnable,$btnDisable,$btnRemove,$btnBackup,$btnRestore,$btnOpen,$btnCsv))

# --- ステータスバー (件数表示。ボタン列と分離して隠れないように) ---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$status = New-Object System.Windows.Forms.ToolStripStatusLabel
[void]$statusStrip.Items.Add($status)
$form.Controls.Add($statusStrip)

# --- 項目キャッシュ ---
# 再列挙(タスクスケジューラ照会など)は重いので、検索のたびには行わずキャッシュから描画する。
$script:CachedItems = @()
$script:PubCache = @{}   # 実行ファイルパス → 発行元 のキャッシュ

function Reload-Items {
    $items = @()
    try { $items = Get-AllStartupItems -IncludeSystemTasks ($chkSystem.Checked) } catch {}
    $runningSet = @{}
    try { $runningSet = Get-RunningExeSet } catch {}
    foreach ($it in $items) {
        $seg = ([string]$it.Command -split ' \| ')[0]
        $exe = Get-ExecutablePath $seg
        $missing = $false
        if (-not $exe -and $seg.Trim()) {
            # 先頭トークンを取り出して判定 (引用符/環境変数/PATH解決に対応)
            $first = $seg.Trim()
            if ($first.StartsWith('"')) {
                $q = $first.IndexOf('"', 1)
                if ($q -gt 1) { $first = $first.Substring(1, $q - 1) }
            } else {
                $first = ($first -split ' ')[0]
            }
            $first = [Environment]::ExpandEnvironmentVariables($first)
            if ($first -and $first.Contains('\')) {
                if (Test-Path -LiteralPath $first) { $exe = $first } else { $missing = $true }
            } elseif ($first) {
                try { $exe = (Get-Command $first -ErrorAction Stop).Source } catch {}
            }
        }
        $pub = ''
        if ($exe) {
            if ($script:PubCache.ContainsKey($exe)) { $pub = $script:PubCache[$exe] }
            else {
                try { $pub = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).CompanyName } catch {}
                if (-not $pub) { $pub = '' }
                $script:PubCache[$exe] = $pub
            }
        }
        $isRunning = ($null -ne $exe -and $runningSet.ContainsKey($exe.ToLower()))
        $it | Add-Member -NotePropertyName ExePath   -NotePropertyValue $exe       -Force
        $it | Add-Member -NotePropertyName Publisher -NotePropertyValue $pub       -Force
        $it | Add-Member -NotePropertyName Missing   -NotePropertyValue $missing   -Force
        $it | Add-Member -NotePropertyName IsRunning -NotePropertyValue $isRunning -Force
    }
    $script:CachedItems = @($items)
}

# --- 一覧の再描画 (キャッシュから) ---
function Refresh-List {
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $filter = $txtSearch.Text.Trim()

    $thirdPartyOnly = $chkThirdParty.Checked
    $visible = @($script:CachedItems | Where-Object {
        if ($thirdPartyOnly -and -not (Test-IsThirdParty $_)) { return $false }
        if ($filter -eq '') { return $true }
        $hay = ($_.Name + ' ' + $_.Type + ' ' + $_.Publisher + ' ' + $_.Command)
        $hay.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })

    # ソート: 列見出しクリックで切替。未クリック時は既定 (無効を先頭 → 分類 → 名前)
    switch ($script:SortColumn) {
        0 { $sorted = $visible | Sort-Object Enabled, Name }
        1 { $sorted = $visible | Sort-Object Name }
        2 { $sorted = $visible | Sort-Object Type, Name }
        3 { $sorted = $visible | Sort-Object Publisher, Name }
        4 { $sorted = $visible | Sort-Object @{E={ Get-ItemLocation $_ }}, Name }
        5 { $sorted = $visible | Sort-Object Command }
        default { $sorted = $visible | Sort-Object @{E={ -not $_.Enabled }}, Kind, Name }
    }
    $sorted = @($sorted)
    if ($script:SortColumn -ge 0 -and -not $script:SortAsc) { [Array]::Reverse($sorted) }

    foreach ($it in $sorted) {
        $statusText = '有効'; if (-not $it.Enabled) { $statusText = '無効' }
        $pubText = [string]$it.Publisher
        if ($it.Missing) { $pubText = '(ファイルが見つかりません)' }
        $lvi = New-Object System.Windows.Forms.ListViewItem($statusText)
        [void]$lvi.SubItems.Add([string]$it.Name)
        [void]$lvi.SubItems.Add([string]$it.Type)
        [void]$lvi.SubItems.Add($pubText)
        [void]$lvi.SubItems.Add((Get-ItemLocation $it))
        [void]$lvi.SubItems.Add([string]$it.Command)
        if ($it.Missing) { $lvi.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif (-not $it.Enabled) { $lvi.ForeColor = [System.Drawing.Color]::Gray }
        $tip = [string]$it.Command
        $tip += "`r`n起動場所: " + (Get-ItemLocation $it)
        if ($it.ExePath) { $tip += "`r`n実行ファイル: $($it.ExePath)" }
        if ($it.IsRunning) { $tip += "`r`n▶ 現在実行中" }
        if ($it.Missing) { $tip += "`r`n⚠ ファイルが見つかりません" }
        $lvi.ToolTipText = $tip
        # アイコン (exeまたはショートカットから取得しキャッシュ)
        $iconSrc = $it.ExePath
        if (-not $iconSrc -and $it.FilePath) { $iconSrc = $it.FilePath }
        if ($iconSrc -and (Test-Path -LiteralPath $iconSrc)) {
            if (-not $imgList.Images.ContainsKey($iconSrc)) {
                try {
                    $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($iconSrc)
                    if ($ic) { $imgList.Images.Add($iconSrc, $ic) }
                } catch {}
            }
            if ($imgList.Images.ContainsKey($iconSrc)) { $lvi.ImageKey = $iconSrc }
        }
        $lvi.Tag = $it
        [void]$lv.Items.Add($lvi)
    }
    $lv.EndUpdate()

    $disabled = @($visible | Where-Object { -not $_.Enabled }).Count
    $broken = @($visible | Where-Object { $_.Missing }).Count
    $text = '{0} 件を表示中 (有効 {1} / 無効 {2}' -f @($visible).Count, (@($visible).Count - $disabled), $disabled
    if ($broken -gt 0) { $text += " / リンク切れ $broken" }
    $text += ')'
    if ($thirdPartyOnly) {
        $msCount = @($script:CachedItems | Where-Object { -not (Test-IsThirdParty $_) }).Count
        if ($msCount -gt 0) { $text += " ｜ Microsoft/標準 $msCount 件を非表示" }
    }
    $script:StatusBase = $text
    $status.Text = $script:StatusBase
}

# 再列挙 + 再描画 (状態変更・削除・更新ボタン用)
function Update-List {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Reload-Items
        Refresh-List
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Get-SelectedItems {
    $sel = @()
    foreach ($i in $lv.SelectedItems) { $sel += $i.Tag }
    return $sel
}

function Invoke-OnSelection {
    param([scriptblock]$Action, [string]$Verb)
    $sel = Get-SelectedItems
    if ($sel.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('対象を一覧から選択してください。', $Verb) | Out-Null
        return $false
    }
    $fail = @()
    foreach ($it in $sel) {
        try { & $Action $it }
        catch { $fail += ('{0} : {1}' -f $it.Name, $_.Exception.Message) }
    }
    if ($fail.Count -gt 0) {
        $msg = "一部の項目で失敗しました（管理者権限が必要な場合があります）:`r`n`r`n" + ($fail -join "`r`n")
        [System.Windows.Forms.MessageBox]::Show($msg, $Verb) | Out-Null
    }
    Update-List
    return $true
}

# --- 右クリックメニュー ---
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miEnable  = $ctx.Items.Add('有効化')
$miDisable = $ctx.Items.Add('無効化')
[void]$ctx.Items.Add('-')
$miOpenLoc = $ctx.Items.Add('ファイルの場所を開く')
$miOpenSrc = $ctx.Items.Add('定義元を開く (レジストリ/タスク/フォルダ)')
$miCopyCmd = $ctx.Items.Add('コマンドをコピー')
$miSearch  = $ctx.Items.Add('この名前をWebで検索')
$miDetail  = $ctx.Items.Add('詳細を表示')
[void]$ctx.Items.Add('-')
$miSelDis    = $ctx.Items.Add('無効の項目をすべて選択')
$miSelBroken = $ctx.Items.Add('リンク切れの項目をすべて選択')
[void]$ctx.Items.Add('-')
$miRemove  = $ctx.Items.Add('完全削除...')
$lv.ContextMenuStrip = $ctx
$ctx.Add_Opening({
    $has = ($lv.SelectedItems.Count -gt 0)
    foreach ($mi in @($miEnable,$miDisable,$miOpenLoc,$miOpenSrc,$miCopyCmd,$miSearch,$miDetail,$miRemove)) { $mi.Enabled = $has }
})

function Show-ItemDetail {
    param($it)
    $exe = $it.ExePath
    $lines = @(
        "名前: $($it.Name)"
        "種類: $($it.Type)"
        "状態: $(if ($it.Enabled) {'有効'} else {'無効'})"
        "範囲: $(if ($it.Scope -eq 'Machine') {'全ユーザー'} else {'現在のユーザー'})"
        "コマンド: $($it.Command)"
    )
    if ($it.Missing) { $lines += "⚠ 実行ファイルが見つかりません (リンク切れ。削除候補です)" }
    if ($it.IsRunning) { $lines += "実行中: はい (現在このプログラムは動作しています)" }
    if ($it.Kind -eq 'Task' -and $it.TriggerInfo) { $lines += "トリガー: $($it.TriggerInfo)" }
    if (-not $it.Enabled -and $it.ApprovedPath) {
        $d = Get-DisabledDate $it.ApprovedPath $it.ValueName
        if ($d) { $lines += "無効化した日時: $($d.ToString('yyyy/MM/dd HH:mm'))" }
    }
    if ($exe) {
        $lines += "実行ファイル: $exe"
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
            if ($vi.CompanyName)    { $lines += "発行元: $($vi.CompanyName)" }
            if ($vi.FileDescription){ $lines += "説明: $($vi.FileDescription)" }
            if ($vi.FileVersion)    { $lines += "バージョン: $($vi.FileVersion)" }
        } catch {}
        try {
            $fi = Get-Item -LiteralPath $exe -ErrorAction Stop
            $lines += "ファイルの更新日時: $($fi.LastWriteTime.ToString('yyyy/MM/dd'))  (いつ頃入ったものかの目安)"
        } catch {}
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
            $lines += "署名: $(if ($sig.Status -eq 'Valid') { '有効 (' + $sig.SignerCertificate.Subject.Split(',')[0] + ')' } elseif ($sig.Status -eq 'NotSigned') { 'なし' } else { [string]$sig.Status })"
        } catch {}
    }
    if ($it.Kind -eq 'Run')    { $lines += "レジストリ: $($it.RegRoot)" }
    if ($it.Kind -eq 'Folder') { $lines += "ファイル: $($it.FilePath)" }
    if ($it.Kind -eq 'Task')   { $lines += "タスク: $($it.TaskPath)$($it.TaskName)" }
    if ($it.Kind -eq 'Uwp')    { $lines += "パッケージ: $($it.Command)"; $lines += "※ ストアアプリは有効化/無効化のみ対応 (削除はアンインストールで)" }
    $hint = Get-SensitiveHint $it
    if ($hint) { $lines += ''; $lines += "⚠ $hint" }
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), '詳細 - ' + $it.Name) | Out-Null
}

function Open-ItemLocation {
    param($it)
    $target = $null
    if ($it.Kind -eq 'Folder' -and $it.FilePath -and (Test-Path -LiteralPath $it.FilePath)) { $target = $it.FilePath }
    elseif ($it.ExePath) { $target = $it.ExePath }
    if ($target) { Start-Process explorer.exe "/select,`"$target`"" }
    else { [System.Windows.Forms.MessageBox]::Show('実行ファイルの場所を特定できませんでした。', 'ファイルの場所を開く') | Out-Null }
}

# 定義元 (レジストリ / タスクスケジューラ / フォルダ) をそれぞれのツールで開く
function Open-ItemSource {
    param($it)
    switch ($it.Kind) {
        'Run' {
            $full = $it.RegRoot -replace '^HKCU', 'HKEY_CURRENT_USER' -replace '^HKLM', 'HKEY_LOCAL_MACHINE'
            $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            New-ItemProperty -Path $k -Name LastKey -Value ("Computer\" + $full) -PropertyType String -Force | Out-Null
            Start-Process regedit.exe
        }
        'Folder' { if ($it.FolderPath) { Start-Process explorer.exe $it.FolderPath } }
        'Task'   { Start-Process taskschd.msc }
        'Uwp'    { Start-Process 'ms-settings:startupapps' }   # Windows設定の「スタートアップ アプリ」
    }
}

$miEnable.Add_Click({  Invoke-OnSelection -Verb '有効化' -Action { param($it) Set-ItemState -Item $it -Enable $true }  | Out-Null })
$miDisable.Add_Click({ Invoke-OnSelection -Verb '無効化' -Action { param($it) Set-ItemState -Item $it -Enable $false } | Out-Null })
$miOpenLoc.Add_Click({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Open-ItemLocation $sel[0] } })
$miOpenSrc.Add_Click({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Open-ItemSource $sel[0] } })
$miCopyCmd.Add_Click({
    $sel = Get-SelectedItems
    if ($sel.Count -gt 0) {
        $text = ($sel | ForEach-Object { $_.Command }) -join "`r`n"
        if ($text) { [System.Windows.Forms.Clipboard]::SetText($text) }
    }
})
$miSearch.Add_Click({
    $sel = Get-SelectedItems
    if ($sel.Count -gt 0) {
        $name = $sel[0].Name -replace '\.(lnk|exe|bat|cmd)$', ''
        $q = [Uri]::EscapeDataString($name + ' スタートアップ')
        Start-Process ('https://www.google.com/search?q=' + $q)
    }
})
$miDetail.Add_Click({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Show-ItemDetail $sel[0] } })
$miSelDis.Add_Click({
    foreach ($i in $lv.Items) { $i.Selected = (-not $i.Tag.Enabled) }
    $lv.Focus()
})
$miSelBroken.Add_Click({
    foreach ($i in $lv.Items) { $i.Selected = [bool]$i.Tag.Missing }
    $lv.Focus()
})
$miRemove.Add_Click({ $btnRemove.PerformClick() })

$lv.Add_DoubleClick({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Show-ItemDetail $sel[0] } })

# 列見出しクリックでソート切替 (同じ列を再クリックで昇順/降順)
$lv.Add_ColumnClick({
    param($s, $e)
    if ($script:SortColumn -eq $e.Column) { $script:SortAsc = -not $script:SortAsc }
    else { $script:SortColumn = $e.Column; $script:SortAsc = $true }
    Refresh-List
})

# キーボードショートカット: F5=更新, Ctrl+A=全選択, Delete=無効化, Enter=詳細
$lv.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { Update-List; $e.Handled = $true }
    elseif ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
        foreach ($i in $lv.Items) { $i.Selected = $true }
        $e.Handled = $true
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        if ($lv.SelectedItems.Count -gt 0) {
            Invoke-OnSelection -Verb '無効化' -Action { param($it) Set-ItemState -Item $it -Enable $false } | Out-Null
        }
        $e.Handled = $true
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Show-ItemDetail $sel[0] }
        $e.Handled = $true
    }
})

# Escで検索クリア
$txtSearch.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $txtSearch.Clear(); $e.Handled = $true }
})

# F1でヘルプ (オフラインで完結)
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F1) {
        $help = @(
            "StartupManager v$($script:Version)"
            ''
            '■ 基本操作'
            '  一覧から項目を選び、下のボタンで有効化/無効化/完全削除。'
            '  無効化はタスクマネージャーと同じ仕組みで、いつでも元に戻せます。'
            '  完全削除は事前に自動バックアップが作られ、「復元...」で書き戻せます。'
            ''
            '■ キーボード'
            '  F5=更新  Ctrl+A=全選択  Delete=無効化  Enter=詳細  Esc=検索クリア  F1=このヘルプ'
            ''
            '■ 便利機能'
            '  ・「サードパーティのみ」= Microsoft/Windows標準を隠して掃除対象を絞る'
            '  ・重要そうな項目(セキュリティ/ドライバー/同期)は削除前に注意が出ます'
            '  ・行をダブルクリック → 詳細 (発行元/署名/更新日時/注意など)'
            '  ・右クリック → 場所を開く / Webで検索 / 無効・リンク切れの一括選択'
            '  ・exeを一覧にドラッグ&ドロップ → 新規追加'
            '  ・赤字の行 = 実行ファイルが見つからない項目 (削除候補)'
            ''
            '■ コマンドライン'
            '  -List / -Export ファイル.csv / -Backup / -SelfTest'
        ) -join "`r`n"
        [System.Windows.Forms.MessageBox]::Show($help, 'ヘルプ') | Out-Null
        $e.Handled = $true
    }
})

# 選択件数をステータスバーに表示
$lv.Add_SelectedIndexChanged({
    $n = $lv.SelectedItems.Count
    if ($n -gt 0) { $status.Text = $script:StatusBase + " - 選択 $n 件" }
    else { $status.Text = $script:StatusBase }
})

# --- イベント ---
$btnRefresh.Add_Click({ Update-List })
$chkSystem.Add_CheckedChanged({ Update-List })
$chkThirdParty.Add_CheckedChanged({ Refresh-List })   # 発行元はキャッシュ済みなので再列挙不要
$txtSearch.Add_TextChanged({ Refresh-List })

# --- 新規追加ダイアログ (レジストリRun / スタートアップフォルダ) ---
function Show-AddDialog {
    param([string]$PrefillPath)

    $d = New-Object System.Windows.Forms.Form
    $d.Text = '起動項目を新規追加'
    $d.Size = New-Object System.Drawing.Size(480, 330)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false

    $lblN = New-Object System.Windows.Forms.Label
    $lblN.Text = '名前:'; $lblN.Location = New-Object System.Drawing.Point(12, 18); $lblN.AutoSize = $true
    $txtN = New-Object System.Windows.Forms.TextBox
    $txtN.Location = New-Object System.Drawing.Point(110, 15); $txtN.Size = New-Object System.Drawing.Size(340, 24)

    $lblE = New-Object System.Windows.Forms.Label
    $lblE.Text = '実行ファイル:'; $lblE.Location = New-Object System.Drawing.Point(12, 50); $lblE.AutoSize = $true
    $txtE = New-Object System.Windows.Forms.TextBox
    $txtE.Location = New-Object System.Drawing.Point(110, 47); $txtE.Size = New-Object System.Drawing.Size(260, 24)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '参照...'; $btnBrowse.Location = New-Object System.Drawing.Point(378, 45); $btnBrowse.Size = New-Object System.Drawing.Size(72, 27)

    $lblA = New-Object System.Windows.Forms.Label
    $lblA.Text = '引数 (任意):'; $lblA.Location = New-Object System.Drawing.Point(12, 82); $lblA.AutoSize = $true
    $txtA = New-Object System.Windows.Forms.TextBox
    $txtA.Location = New-Object System.Drawing.Point(110, 79); $txtA.Size = New-Object System.Drawing.Size(340, 24)

    # 登録方法 / 対象 はそれぞれ独立した排他グループにする。
    # WinForamsはRadioButtonを「直近の親コンテナ」でグループ化するため、GroupBoxで分けないと
    # 4つのラジオが1グループになり、片方を選ぶともう片方が外れる不具合になる。
    $grpM = New-Object System.Windows.Forms.GroupBox
    $grpM.Text = '登録方法'; $grpM.Location = New-Object System.Drawing.Point(12, 108); $grpM.Size = New-Object System.Drawing.Size(452, 46)
    $rbReg = New-Object System.Windows.Forms.RadioButton
    $rbReg.Text = 'レジストリ Run'; $rbReg.Location = New-Object System.Drawing.Point(12, 16); $rbReg.AutoSize = $true; $rbReg.Checked = $true
    $rbFolder = New-Object System.Windows.Forms.RadioButton
    $rbFolder.Text = 'スタートアップフォルダ (ショートカット)'; $rbFolder.Location = New-Object System.Drawing.Point(150, 16); $rbFolder.AutoSize = $true
    $grpM.Controls.AddRange(@($rbReg, $rbFolder))

    $grpS = New-Object System.Windows.Forms.GroupBox
    $grpS.Text = '対象'; $grpS.Location = New-Object System.Drawing.Point(12, 160); $grpS.Size = New-Object System.Drawing.Size(452, 68)
    $rbUser = New-Object System.Windows.Forms.RadioButton
    $rbUser.Text = '現在のユーザーのみ'; $rbUser.Location = New-Object System.Drawing.Point(12, 16); $rbUser.AutoSize = $true; $rbUser.Checked = $true
    $rbAll = New-Object System.Windows.Forms.RadioButton
    $rbAll.Text = '全ユーザー (管理者権限が必要)'; $rbAll.Location = New-Object System.Drawing.Point(12, 40); $rbAll.AutoSize = $true
    $grpS.Controls.AddRange(@($rbUser, $rbAll))

    $okB = New-Object System.Windows.Forms.Button
    $okB.Text = '追加'; $okB.Location = New-Object System.Drawing.Point(282, 240); $okB.Size = New-Object System.Drawing.Size(80, 30)
    $cancelB = New-Object System.Windows.Forms.Button
    $cancelB.Text = 'キャンセル'; $cancelB.DialogResult = 'Cancel'
    $cancelB.Location = New-Object System.Drawing.Point(372, 240); $cancelB.Size = New-Object System.Drawing.Size(82, 30)

    $d.Controls.AddRange(@($lblN,$txtN,$lblE,$txtE,$btnBrowse,$lblA,$txtA,$grpM,$grpS,$okB,$cancelB))
    $d.AcceptButton = $okB; $d.CancelButton = $cancelB

    # ドロップやファイル指定からの事前入力 (.lnkはリンク先を解決)
    if ($PrefillPath -and (Test-Path -LiteralPath $PrefillPath)) {
        $p = $PrefillPath
        if ([System.IO.Path]::GetExtension($p) -eq '.lnk') {
            try {
                $sh = New-Object -ComObject WScript.Shell
                $sc = $sh.CreateShortcut($p)
                if ($sc.TargetPath) { $txtA.Text = $sc.Arguments; $p = $sc.TargetPath }
            } catch {}
        }
        $txtE.Text = $p
        $txtN.Text = [System.IO.Path]::GetFileNameWithoutExtension($PrefillPath)
    }

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'プログラム (*.exe;*.bat;*.cmd)|*.exe;*.bat;*.cmd|すべてのファイル (*.*)|*.*'
        if ($ofd.ShowDialog($d) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtE.Text = $ofd.FileName
            if (-not $txtN.Text.Trim()) { $txtN.Text = [System.IO.Path]::GetFileNameWithoutExtension($ofd.FileName) }
        }
    })

    $okB.Add_Click({
        $name = $txtN.Text.Trim()
        $exe  = $txtE.Text.Trim('"', ' ')
        if (-not $name) { [System.Windows.Forms.MessageBox]::Show('名前を入力してください。', '新規追加') | Out-Null; return }
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            [System.Windows.Forms.MessageBox]::Show('実行ファイルが存在しません。', '新規追加') | Out-Null; return
        }
        if ($rbAll.Checked -and -not $isAdmin) {
            [System.Windows.Forms.MessageBox]::Show('全ユーザーへの登録には管理者権限が必要です。', '新規追加') | Out-Null; return
        }
        try {
            if ($rbReg.Checked) {
                # レジストリRunに登録
                $key = if ($rbAll.Checked) { $script:RunSources[1].Run } else { $script:RunSources[0].Run }
                $existing = $null
                try { $existing = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch {}
                if ($null -ne $existing) {
                    $r = [System.Windows.Forms.MessageBox]::Show(
                        "同名の項目がすでに存在します:`r`n$existing`r`n`r`n上書きしますか?", '新規追加',
                        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
                $cmd = '"' + $exe + '"'
                if ($txtA.Text.Trim()) { $cmd += ' ' + $txtA.Text.Trim() }
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                New-ItemProperty -Path $key -Name $name -Value $cmd -PropertyType String -Force | Out-Null
            } else {
                # スタートアップフォルダにショートカットを作成
                $dest = if ($rbAll.Checked) { [Environment]::GetFolderPath('CommonStartup') } else { [Environment]::GetFolderPath('Startup') }
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                $safeName = ($name -replace '[\\/:*?"<>|]', '_')
                $lnkPath = Join-Path $dest ($safeName + '.lnk')
                if (Test-Path -LiteralPath $lnkPath) {
                    $r = [System.Windows.Forms.MessageBox]::Show(
                        "同名のショートカットがすでに存在します。上書きしますか?", '新規追加',
                        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
                $sh = New-Object -ComObject WScript.Shell
                $lnk = $sh.CreateShortcut($lnkPath)
                $lnk.TargetPath = $exe
                if ($txtA.Text.Trim()) { $lnk.Arguments = $txtA.Text.Trim() }
                try { $lnk.WorkingDirectory = (Split-Path -Parent $exe) } catch {}
                $lnk.Save()
            }
            $d.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $d.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("追加に失敗しました: $($_.Exception.Message)", '新規追加') | Out-Null
        }
    })

    if ($d.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { Update-List }
}

$btnAdd.Add_Click({ Show-AddDialog })

# 一覧へのドラッグ&ドロップで新規追加 (exeやショートカットを落とすと入力済みで開く)
$lv.AllowDrop = $true
$lv.Add_DragEnter({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$lv.Add_DragDrop({
    param($s, $e)
    $files = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    if ($files.Count -gt 0) { Show-AddDialog -PrefillPath ([string]$files[0]) }
})

$btnEnable.Add_Click({
    Invoke-OnSelection -Verb '有効化' -Action { param($it) Set-ItemState -Item $it -Enable $true } | Out-Null
})

$btnDisable.Add_Click({
    Invoke-OnSelection -Verb '無効化' -Action { param($it) Set-ItemState -Item $it -Enable $false } | Out-Null
})

$btnRemove.Add_Click({
    $sel = Get-SelectedItems
    if ($sel.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('対象を一覧から選択してください。','完全削除') | Out-Null; return }
    $names = ($sel | ForEach-Object { '・' + $_.Name }) -join "`r`n"
    # 重要そうな項目には、削除前にやさしく注意する (影響を平易に)
    $cautions = @()
    foreach ($it in $sel) {
        $h = Get-SensitiveHint $it
        if ($h) { $cautions += ('・{0}: {1}' -f $it.Name, $h) }
    }
    $cautionBlock = ''
    if ($cautions.Count -gt 0) {
        $cautionBlock = "`r`n`r`n⚠ 次の項目は重要かもしれません:`r`n" + ($cautions -join "`r`n") +
                        "`r`n`r`n迷うときは、まず『無効化』(あとで戻せます)をおすすめします。"
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "次の項目を起動項目から完全に削除します。`r`n（削除前に自動でバックアップを作成します）`r`n`r`n$names$cautionBlock`r`n`r`nよろしいですか?",
        '完全削除の確認',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    # 削除のたびに新しいバックアップを作成する (確認ダイアログの約束どおり、毎回保存)
    $script:LastBackupDir = New-FullBackup
    $bk = $script:LastBackupDir
    # スクリプトブロック内から確実に参照できるよう script スコープの変数を使う
    Invoke-OnSelection -Verb '完全削除' -Action { param($it) Remove-ItemHard -Item $it -BackupDir $script:LastBackupDir } | Out-Null
    [System.Windows.Forms.MessageBox]::Show("削除しました。`r`nバックアップ場所:`r`n$bk", '完全削除') | Out-Null
})

$btnBackup.Add_Click({
    try {
        $bk = New-FullBackup
        [System.Windows.Forms.MessageBox]::Show("バックアップを作成しました:`r`n$bk", 'バックアップ') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("失敗: $($_.Exception.Message)", 'バックアップ') | Out-Null
    }
})

$btnOpen.Add_Click({
    if (-not (Test-Path $script:BackupRoot)) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null }
    Start-Process explorer.exe $script:BackupRoot
})

$btnRestore.Add_Click({
    if (-not (Test-Path $script:BackupRoot)) {
        [System.Windows.Forms.MessageBox]::Show('バックアップがまだありません。', '復元') | Out-Null; return
    }
    $dirs = @(Get-ChildItem -Path $script:BackupRoot -Directory | Sort-Object Name -Descending)
    if ($dirs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('バックアップがまだありません。', '復元') | Out-Null; return
    }

    # バックアップ選択ダイアログ
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '復元するバックアップを選択'
    $dlg.Size = New-Object System.Drawing.Size(360, 380)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12, 12)
    $lst.Size = New-Object System.Drawing.Size(320, 260)
    foreach ($d in $dirs) {
        # フォルダ名 yyyyMMdd_HHmmss を読みやすく表示
        $label = $d.Name
        if ($d.Name -match '^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$') {
            $label = '{0}/{1}/{2} {3}:{4}:{5}' -f $Matches[1],$Matches[2],$Matches[3],$Matches[4],$Matches[5],$Matches[6]
        }
        [void]$lst.Items.Add($label)
    }
    $lst.SelectedIndex = 0
    $dlg.Controls.Add($lst)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '復元'; $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point(160, 290); $ok.Size = New-Object System.Drawing.Size(80, 30)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'キャンセル'; $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(250, 290); $cancel.Size = New-Object System.Drawing.Size(82, 30)
    $dlg.Controls.AddRange(@($ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK -or $lst.SelectedIndex -lt 0) { return }
    $target = $dirs[$lst.SelectedIndex]

    $r = [System.Windows.Forms.MessageBox]::Show(
        "バックアップ「$($lst.SelectedItem)」の内容を書き戻します。`r`n現在の起動項目の設定は上書きされます。`r`n`r`nよろしいですか?",
        '復元の確認',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $log = Restore-FromBackup -Dir $target.FullName
    Update-List
    [System.Windows.Forms.MessageBox]::Show(("復元結果:`r`n`r`n" + ($log -join "`r`n")), '復元') | Out-Null
})

$btnCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSVファイル (*.csv)|*.csv'
    $dlg.FileName = 'StartupItems_' + (Get-Date -Format 'yyyyMMdd') + '.csv'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $items = Get-AllStartupItems -IncludeSystemTasks ($chkSystem.Checked)
        Export-ItemsCsv -Items $items -Path $dlg.FileName
        [System.Windows.Forms.MessageBox]::Show("書き出しました:`r`n$($dlg.FileName)", 'CSV出力') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("失敗: $($_.Exception.Message)", 'CSV出力') | Out-Null
    }
})

Update-List
[void]$form.ShowDialog()
