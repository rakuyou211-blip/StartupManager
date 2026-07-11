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
    [string]$Export
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.1.0'

# ============================================================
# 共通設定
# ============================================================
$script:BackupRoot = Join-Path $PSScriptRoot 'Backups'
$script:SessionBackupDone = $false
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
    foreach ($src in $script:FolderSources) {
        if (-not $src.Path -or -not (Test-Path $src.Path)) { continue }
        $files = Get-ChildItem -Path $src.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }
        foreach ($f in $files) {
            $state = Get-ApprovedState $src.Approved $f.Name
            $enabled = $true; if ($null -ne $state) { $enabled = $state }
            $target = $f.FullName
            if ($f.Extension -eq '.lnk') {
                try { $sh = New-Object -ComObject WScript.Shell; $target = ($sh.CreateShortcut($f.FullName)).TargetPath } catch {}
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
        foreach ($tr in $trigs) {
            $cn = $null
            try { $cn = $tr.CimClass.CimClassName } catch {}
            if ($cn -eq 'MSFT_TaskLogonTrigger' -or $cn -eq 'MSFT_TaskBootTrigger') { $isLogon = $true; break }
        }
        if (-not $isLogon) { continue }
        if (-not $IncludeSystem -and $t.TaskPath -like '\Microsoft\*') { continue }
        $exec = ''
        try { $exec = (($t.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() }) -join ' | ') } catch {}
        $enabled = ($t.State -ne 'Disabled')
        $result += [pscustomobject]@{
            Enabled=$enabled; Name=$t.TaskName; Type='タスク(ログオン/起動)'; Command=$exec;
            Kind='Task'; RunPath=''; RegRoot=''; ApprovedPath=''; ValueName='';
            Scope='Machine'; TaskName=$t.TaskName; TaskPath=$t.TaskPath; FolderPath=''; FilePath=''
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
    return $all
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

function Export-ItemsCsv {
    param($Items, [string]$Path)
    $Items | Sort-Object Kind, Type, Name | Select-Object `
        @{N='状態';   E={ if ($_.Enabled) { '有効' } else { '無効' } }},
        @{N='名前';   E={ $_.Name }},
        @{N='種類';   E={ $_.Type }},
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

function Ensure-SessionBackup {
    if ($script:SessionBackupDone) { return $script:LastBackupDir }
    $script:LastBackupDir = New-FullBackup
    $script:SessionBackupDone = $true
    return $script:LastBackupDir
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
    }
}

function Remove-ItemHard {
    param($Item, $BackupDir)
    switch ($Item.Kind) {
        'Run' {
            Remove-ItemProperty -Path $Item.RunPath      -Name $Item.ValueName -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $Item.ApprovedPath -Name $Item.ValueName -ErrorAction SilentlyContinue
        }
        'Folder' {
            if (Test-Path $Item.FilePath) {
                try { Move-Item -Path $Item.FilePath -Destination (Join-Path $BackupDir ('removed_' + $Item.ValueName)) -Force }
                catch { Remove-Item -Path $Item.FilePath -Force -ErrorAction SilentlyContinue }
            }
            Remove-ItemProperty -Path $Item.ApprovedPath -Name $Item.ValueName -ErrorAction SilentlyContinue
        }
        'Task' {
            try {
                $safe = ($Item.TaskName -replace '[\\/:*?"<>|]', '_')
                Export-ScheduledTask -TaskName $Item.TaskName -TaskPath $Item.TaskPath |
                    Out-File (Join-Path $BackupDir ('task_' + $safe + '.xml')) -Encoding utf8
            } catch {}
            Unregister-ScheduledTask -TaskName $Item.TaskName -TaskPath $Item.TaskPath -Confirm:$false
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
    Write-Output ("--- 合計 {0} 件 (Run/Folder/Task, システムタスク除く) ---" -f $items.Count)
    return
}

if ($Export) {
    $items = Get-AllStartupItems -IncludeSystemTasks $false
    Export-ItemsCsv -Items $items -Path $Export
    Write-Output ("{0} 件を書き出しました: {1}" -f $items.Count, (Resolve-Path $Export).Path)
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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

$form = New-Object System.Windows.Forms.Form
$form.Text = "StartupManager v$($script:Version) - 起動時に自動起動するソフトの管理"
$form.Size = New-Object System.Drawing.Size(960, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(760, 460)

# --- 上部: 検索 / オプション ---
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = '絞り込み:'
$lblSearch.Location = New-Object System.Drawing.Point(12, 15)
$lblSearch.AutoSize = $true
$form.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(75, 12)
$txtSearch.Size = New-Object System.Drawing.Size(240, 24)
$txtSearch.Anchor = 'Top,Left'
$form.Controls.Add($txtSearch)

$chkSystem = New-Object System.Windows.Forms.CheckBox
$chkSystem.Text = 'システムのタスクも表示'
$chkSystem.Location = New-Object System.Drawing.Point(330, 13)
$chkSystem.AutoSize = $true
$form.Controls.Add($chkSystem)

$lblAdmin = New-Object System.Windows.Forms.Label
$lblAdmin.AutoSize = $true
$lblAdmin.Location = New-Object System.Drawing.Point(500, 15)
if ($isAdmin) { $lblAdmin.Text = '管理者: 有効 (全項目を操作可)'; $lblAdmin.ForeColor = [System.Drawing.Color]::Green }
else          { $lblAdmin.Text = '管理者: 無効 (システム項目は操作不可)'; $lblAdmin.ForeColor = [System.Drawing.Color]::Firebrick }
$lblAdmin.Anchor = 'Top,Right'
$form.Controls.Add($lblAdmin)

# --- 一覧 ---
$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(12, 45)
$lv.Size = New-Object System.Drawing.Size(920, 470)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.MultiSelect = $true
$lv.Anchor = 'Top,Bottom,Left,Right'
[void]$lv.Columns.Add('状態', 60)
[void]$lv.Columns.Add('名前', 230)
[void]$lv.Columns.Add('種類', 170)
[void]$lv.Columns.Add('コマンド / パス', 440)
$form.Controls.Add($lv)

# 列クリックソートの状態 (-1 = 既定ソート: 無効を先頭 → 分類 → 名前)
$script:SortColumn = -1
$script:SortAsc = $true

# --- 下部ボタン ---
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Location = New-Object System.Drawing.Point(12, 525)
$panel.Size = New-Object System.Drawing.Size(920, 50)
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
$btnEnable  = New-Btn '有効化' 90
$btnDisable = New-Btn '無効化' 90
$btnRemove  = New-Btn '完全削除' 110
$btnBackup  = New-Btn 'バックアップ作成' 140
$btnOpen    = New-Btn '保存場所を開く' 130
$btnCsv     = New-Btn 'CSV出力' 90
$panel.Controls.AddRange(@($btnRefresh,$btnEnable,$btnDisable,$btnRemove,$btnBackup,$btnOpen,$btnCsv))

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $true
$status.Margin = New-Object System.Windows.Forms.Padding(12,9,0,0)
$panel.Controls.Add($status)

# --- 一覧の再描画 ---
function Refresh-List {
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $items = @()
    try { $items = Get-AllStartupItems -IncludeSystemTasks ($chkSystem.Checked) } catch {}
    $filter = $txtSearch.Text.Trim()

    $visible = @($items | Where-Object {
        if ($filter -eq '') { return $true }
        $hay = ($_.Name + ' ' + $_.Type + ' ' + $_.Command)
        $hay.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })

    # ソート: 列見出しクリックで切替。未クリック時は既定 (無効を先頭 → 分類 → 名前)
    switch ($script:SortColumn) {
        0 { $sorted = $visible | Sort-Object Enabled, Name }
        1 { $sorted = $visible | Sort-Object Name }
        2 { $sorted = $visible | Sort-Object Type, Name }
        3 { $sorted = $visible | Sort-Object Command }
        default { $sorted = $visible | Sort-Object @{E={ -not $_.Enabled }}, Kind, Name }
    }
    $sorted = @($sorted)
    if ($script:SortColumn -ge 0 -and -not $script:SortAsc) { [Array]::Reverse($sorted) }

    foreach ($it in $sorted) {
        $statusText = '有効'; if (-not $it.Enabled) { $statusText = '無効' }
        $lvi = New-Object System.Windows.Forms.ListViewItem($statusText)
        [void]$lvi.SubItems.Add([string]$it.Name)
        [void]$lvi.SubItems.Add([string]$it.Type)
        [void]$lvi.SubItems.Add([string]$it.Command)
        if (-not $it.Enabled) { $lvi.ForeColor = [System.Drawing.Color]::Gray }
        $lvi.Tag = $it
        [void]$lv.Items.Add($lvi)
    }
    $lv.EndUpdate()

    $disabled = @($visible | Where-Object { -not $_.Enabled }).Count
    $status.Text = ('{0} 件を表示中 (有効 {1} / 無効 {2})' -f @($visible).Count, (@($visible).Count - $disabled), $disabled)
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
    Refresh-List
    return $true
}

# --- 右クリックメニュー ---
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miEnable  = $ctx.Items.Add('有効化')
$miDisable = $ctx.Items.Add('無効化')
[void]$ctx.Items.Add('-')
$miOpenLoc = $ctx.Items.Add('ファイルの場所を開く')
$miCopyCmd = $ctx.Items.Add('コマンドをコピー')
$miDetail  = $ctx.Items.Add('詳細を表示')
[void]$ctx.Items.Add('-')
$miRemove  = $ctx.Items.Add('完全削除...')
$lv.ContextMenuStrip = $ctx
$ctx.Add_Opening({
    $has = ($lv.SelectedItems.Count -gt 0)
    foreach ($mi in @($miEnable,$miDisable,$miOpenLoc,$miCopyCmd,$miDetail,$miRemove)) { $mi.Enabled = $has }
})

function Show-ItemDetail {
    param($it)
    $exe = Get-ExecutablePath $it.Command
    $lines = @(
        "名前: $($it.Name)"
        "種類: $($it.Type)"
        "状態: $(if ($it.Enabled) {'有効'} else {'無効'})"
        "範囲: $(if ($it.Scope -eq 'Machine') {'全ユーザー'} else {'現在のユーザー'})"
        "コマンド: $($it.Command)"
    )
    if ($exe) {
        $lines += "実行ファイル: $exe"
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
            if ($vi.CompanyName)    { $lines += "発行元: $($vi.CompanyName)" }
            if ($vi.FileDescription){ $lines += "説明: $($vi.FileDescription)" }
        } catch {}
    }
    if ($it.Kind -eq 'Run')    { $lines += "レジストリ: $($it.RegRoot)" }
    if ($it.Kind -eq 'Folder') { $lines += "ファイル: $($it.FilePath)" }
    if ($it.Kind -eq 'Task')   { $lines += "タスク: $($it.TaskPath)$($it.TaskName)" }
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), '詳細 - ' + $it.Name) | Out-Null
}

function Open-ItemLocation {
    param($it)
    $target = $null
    if ($it.Kind -eq 'Folder' -and $it.FilePath -and (Test-Path -LiteralPath $it.FilePath)) { $target = $it.FilePath }
    else { $target = Get-ExecutablePath $it.Command }
    if ($target) { Start-Process explorer.exe "/select,`"$target`"" }
    else { [System.Windows.Forms.MessageBox]::Show('実行ファイルの場所を特定できませんでした。', 'ファイルの場所を開く') | Out-Null }
}

$miEnable.Add_Click({  Invoke-OnSelection -Verb '有効化' -Action { param($it) Set-ItemState -Item $it -Enable $true }  | Out-Null })
$miDisable.Add_Click({ Invoke-OnSelection -Verb '無効化' -Action { param($it) Set-ItemState -Item $it -Enable $false } | Out-Null })
$miOpenLoc.Add_Click({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Open-ItemLocation $sel[0] } })
$miCopyCmd.Add_Click({
    $sel = Get-SelectedItems
    if ($sel.Count -gt 0) {
        $text = ($sel | ForEach-Object { $_.Command }) -join "`r`n"
        if ($text) { [System.Windows.Forms.Clipboard]::SetText($text) }
    }
})
$miDetail.Add_Click({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Show-ItemDetail $sel[0] } })
$miRemove.Add_Click({ $btnRemove.PerformClick() })

$lv.Add_DoubleClick({ $sel = Get-SelectedItems; if ($sel.Count -gt 0) { Show-ItemDetail $sel[0] } })

# 列見出しクリックでソート切替 (同じ列を再クリックで昇順/降順)
$lv.Add_ColumnClick({
    param($s, $e)
    if ($script:SortColumn -eq $e.Column) { $script:SortAsc = -not $script:SortAsc }
    else { $script:SortColumn = $e.Column; $script:SortAsc = $true }
    Refresh-List
})

# --- イベント ---
$btnRefresh.Add_Click({ Refresh-List })
$chkSystem.Add_CheckedChanged({ Refresh-List })
$txtSearch.Add_TextChanged({ Refresh-List })

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
    $r = [System.Windows.Forms.MessageBox]::Show(
        "次の項目を起動項目から完全に削除します。`r`n（削除前に自動でバックアップを作成します）`r`n`r`n$names`r`n`r`nよろしいですか?",
        '完全削除の確認',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $bk = Ensure-SessionBackup
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

Refresh-List
[void]$form.ShowDialog()
