#!/bin/bash
#
# StartupManager.command - macOS版 スタートアップ管理ツール (CLI)
# ログイン時に自動起動する項目を一覧表示し、無効化・有効化・削除(バックアップつき)できます。
# 対象: ユーザーLaunchAgents / 全体LaunchAgents / LaunchDaemons / ログイン項目
# macOS標準のコマンド(launchctl / PlistBuddy / osascript)のみ使用。追加インストール不要・完全オフライン動作。
#
# 使い方:
#   ダブルクリック (ターミナルが開きます) または  ./StartupManager.command
#   ./StartupManager.command --list             (一覧表示のみ)
#   ./StartupManager.command --export out.csv   (CSV出力)
#   ./StartupManager.command --backup           (バックアップのみ作成)
#   ./StartupManager.command --selftest         (動作セルフテスト)
#
set -u

VERSION="1.7.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="$SCRIPT_DIR/Backups"
PLISTBUDDY="/usr/libexec/PlistBuddy"
UID_NUM="$(id -u)"

if [ "$(uname)" != "Darwin" ]; then
    echo "このスクリプトは macOS 専用です。Windows では StartupManager.bat を使ってください。"
    exit 1
fi

# ============================================================
# 収集 (bash 3.2 互換: 連想配列は使わない)
# ============================================================
ITEM_LABEL=()   # launchctlのラベル / ログイン項目名
ITEM_PATH=()    # plistのパス (ログイン項目は空)
ITEM_TYPE=()    # UserAgent / GlobalAgent / Daemon / LoginItem
ITEM_DOMAIN=()  # gui/501 など / system
ITEM_STATE=()   # 有効 / 無効 / 不明
ITEM_PROG=()    # 実行プログラム

plist_label() {
    "$PLISTBUDDY" -c "Print :Label" "$1" 2>/dev/null || basename "$1" .plist
}

plist_program() {
    "$PLISTBUDDY" -c "Print :Program" "$1" 2>/dev/null && return
    "$PLISTBUDDY" -c "Print :ProgramArguments:0" "$1" 2>/dev/null && return
    echo ""
}

is_disabled() {
    # $1=domain $2=label。launchctlの無効化オーバーライドに載っているか
    launchctl print-disabled "$1" 2>/dev/null | grep -Eq "\"$2\" => (disabled|true)"
}

add_plist_dir() {
    # $1=ディレクトリ $2=種別 $3=domain
    local f label prog state
    [ -d "$1" ] || return 0
    for f in "$1"/*.plist; do
        [ -e "$f" ] || continue
        label="$(plist_label "$f")"
        prog="$(plist_program "$f")"
        if is_disabled "$3" "$label"; then state="無効"; else state="有効"; fi
        ITEM_LABEL+=("$label"); ITEM_PATH+=("$f"); ITEM_TYPE+=("$2")
        ITEM_DOMAIN+=("$3"); ITEM_STATE+=("$state"); ITEM_PROG+=("$prog")
    done
}

add_login_items() {
    local names line
    names="$(osascript 2>/dev/null <<'EOF'
tell application "System Events"
    set outText to ""
    repeat with li in login items
        set outText to outText & (name of li) & linefeed
    end repeat
end tell
return outText
EOF
)" || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        ITEM_LABEL+=("$line"); ITEM_PATH+=(""); ITEM_TYPE+=("LoginItem")
        ITEM_DOMAIN+=(""); ITEM_STATE+=("有効"); ITEM_PROG+=("(ログイン項目)")
    done <<< "$names"
}

collect() {
    ITEM_LABEL=(); ITEM_PATH=(); ITEM_TYPE=(); ITEM_DOMAIN=(); ITEM_STATE=(); ITEM_PROG=()
    add_plist_dir "$HOME/Library/LaunchAgents" "UserAgent"   "gui/$UID_NUM"
    add_plist_dir "/Library/LaunchAgents"      "GlobalAgent" "gui/$UID_NUM"
    add_plist_dir "/Library/LaunchDaemons"     "Daemon"      "system"
    add_login_items
}

type_name() {
    case "$1" in
        UserAgent)   echo "エージェント(ユーザー)" ;;
        GlobalAgent) echo "エージェント(全体)" ;;
        Daemon)      echo "デーモン(要sudo)" ;;
        LoginItem)   echo "ログイン項目" ;;
    esac
}

show_list() {
    local i n
    n=${#ITEM_LABEL[@]}
    echo ""
    printf "%-4s %-4s %-24s %-32s %s\n" "No." "状態" "種類" "名前" "プログラム"
    printf -- "----------------------------------------------------------------------------------------------\n"
    i=0
    while [ $i -lt $n ]; do
        printf "%-4s %-4s %-24s %-32s %s\n" \
            "$((i+1))" "${ITEM_STATE[$i]}" "$(type_name "${ITEM_TYPE[$i]}")" "${ITEM_LABEL[$i]}" "${ITEM_PROG[$i]}"
        i=$((i+1))
    done
    echo ""
    echo "--- 合計 $n 件 ---"
}

# ============================================================
# バックアップ / 復元
# ============================================================
make_backup() {
    local ts dir i
    ts="$(date +%Y%m%d_%H%M%S)"
    dir="$BACKUP_ROOT/$ts"
    mkdir -p "$dir"
    i=0
    while [ $i -lt ${#ITEM_LABEL[@]} ]; do
        if [ -n "${ITEM_PATH[$i]}" ] && [ -f "${ITEM_PATH[$i]}" ]; then
            cp "${ITEM_PATH[$i]}" "$dir/${ITEM_TYPE[$i]}_$(basename "${ITEM_PATH[$i]}")" 2>/dev/null
        fi
        i=$((i+1))
    done
    osascript -e 'tell application "System Events" to get the name of every login item' > "$dir/login_items.txt" 2>/dev/null
    echo "$dir"
}

restore_menu() {
    local dirs d i sel src name dest
    [ -d "$BACKUP_ROOT" ] || { echo "バックアップがまだありません。"; return; }
    dirs=()
    for d in "$BACKUP_ROOT"/*/; do [ -d "$d" ] && dirs+=("${d%/}"); done
    [ ${#dirs[@]} -gt 0 ] || { echo "バックアップがまだありません。"; return; }
    echo ""
    i=0
    while [ $i -lt ${#dirs[@]} ]; do
        echo "  $((i+1))) $(basename "${dirs[$i]}")"
        i=$((i+1))
    done
    printf "復元するバックアップ番号 (中止=Enter): "
    read -r sel
    [ -n "$sel" ] || return
    case "$sel" in (*[!0-9]*|'') echo "無効な番号です。"; return ;; esac
    [ "$sel" -ge 1 ] && [ "$sel" -le ${#dirs[@]} ] || { echo "無効な番号です。"; return; }
    src="${dirs[$((sel-1))]}"
    echo "plistを元の場所へコピーします (既存は上書き)。"
    for f in "$src"/*.plist; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        case "$name" in
            UserAgent_*)   dest="$HOME/Library/LaunchAgents/${name#UserAgent_}";  cp "$f" "$dest" && echo "OK: $dest" ;;
            GlobalAgent_*) dest="/Library/LaunchAgents/${name#GlobalAgent_}";     sudo cp "$f" "$dest" && echo "OK: $dest" ;;
            Daemon_*)      dest="/Library/LaunchDaemons/${name#Daemon_}";         sudo cp "$f" "$dest" && echo "OK: $dest" ;;
        esac
    done
    echo "完了。反映には再ログインまたは再起動が必要な場合があります。"
}

# ============================================================
# CSVエクスポート
# ============================================================
csv_escape() {
    local s="${1//\"/\"\"}"
    printf '"%s"' "$s"
}

export_csv() {
    local out="$1" i
    {
        printf '状態,名前,種類,プログラム,パス\n'
        i=0
        while [ $i -lt ${#ITEM_LABEL[@]} ]; do
            printf '%s,%s,%s,%s,%s\n' \
                "$(csv_escape "${ITEM_STATE[$i]}")" \
                "$(csv_escape "${ITEM_LABEL[$i]}")" \
                "$(csv_escape "$(type_name "${ITEM_TYPE[$i]}")")" \
                "$(csv_escape "${ITEM_PROG[$i]}")" \
                "$(csv_escape "${ITEM_PATH[$i]}")"
            i=$((i+1))
        done
    } > "$out"
    echo "${#ITEM_LABEL[@]} 件を書き出しました: $out"
}

# ============================================================
# セルフテスト (システムの実項目には一切触れない)
# ============================================================
ST_FAILS=0
st_assert() {
    # $1=直前コマンドの終了コード扱い(0=成功) $2=ラベル
    if [ "$1" -eq 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; ST_FAILS=$((ST_FAILS+1)); fi
}

run_selftest() {
    echo "== StartupManager for macOS v$VERSION セルフテスト =="
    local idx tmp dir tmpcsv rc

    # 番号→インデックス変換
    ITEM_LABEL=(a b c); ITEM_PATH=("" "" ""); ITEM_TYPE=(UserAgent UserAgent UserAgent)
    ITEM_DOMAIN=("" "" ""); ITEM_STATE=("有効" "有効" "有効"); ITEM_PROG=("" "" "")
    idx="$(pick_index 2)"; [ "$idx" = "1" ]; st_assert $? "番号からインデックスへの変換"
    pick_index 0 >/dev/null 2>&1; rc=$?; [ $rc -ne 0 ]; st_assert $? "範囲外の番号(0)を拒否"
    pick_index abc >/dev/null 2>&1; rc=$?; [ $rc -ne 0 ]; st_assert $? "数字以外の入力を拒否"
    pick_index 4 >/dev/null 2>&1; rc=$?; [ $rc -ne 0 ]; st_assert $? "範囲外の番号(上限超え)を拒否"

    # plistの列挙 (一時フォルダ内のダミーで検証)
    tmp="$(mktemp -d 2>/dev/null || mktemp -d -t smtest)"
    cat > "$tmp/com.example.selftest.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.example.selftest</string></dict></plist>
PLIST
    ITEM_LABEL=(); ITEM_PATH=(); ITEM_TYPE=(); ITEM_DOMAIN=(); ITEM_STATE=(); ITEM_PROG=()
    add_plist_dir "$tmp" "UserAgent" "gui/$UID_NUM"
    [ ${#ITEM_LABEL[@]} -eq 1 ]; st_assert $? "plistの列挙"

    # バックアップにダミーplistが含まれる
    dir="$(make_backup)"
    [ -d "$dir" ] && ls "$dir" 2>/dev/null | grep -q "com.example.selftest.plist"
    st_assert $? "バックアップにplistが含まれる"
    rm -rf "$dir" 2>/dev/null

    # CSVエクスポート
    tmpcsv="$(mktemp 2>/dev/null || mktemp -t smtest_csv)"
    export_csv "$tmpcsv" >/dev/null
    head -1 "$tmpcsv" | grep -q "名前"; st_assert $? "CSVエクスポート"
    rm -f "$tmpcsv" "$tmp/com.example.selftest.plist" 2>/dev/null
    rmdir "$tmp" 2>/dev/null

    if [ $ST_FAILS -eq 0 ]; then
        echo "== 全テスト合格 =="
    else
        echo "== $ST_FAILS 件失敗 =="
        exit 1
    fi
}

# ============================================================
# 操作
# ============================================================
need_sudo() {
    case "$1" in Daemon) return 0 ;; *) return 1 ;; esac
}

do_disable() {
    local i=$1 lc="launchctl"
    case "${ITEM_TYPE[$i]}" in
        LoginItem) echo "ログイン項目に無効化はありません。削除(r)を使ってください。"; return ;;
    esac
    need_sudo "${ITEM_TYPE[$i]}" && lc="sudo launchctl"
    $lc bootout "${ITEM_DOMAIN[$i]}/${ITEM_LABEL[$i]}" 2>/dev/null
    if $lc disable "${ITEM_DOMAIN[$i]}/${ITEM_LABEL[$i]}"; then
        echo "無効化しました: ${ITEM_LABEL[$i]} (いつでも有効化で戻せます)"
    else
        echo "失敗しました: ${ITEM_LABEL[$i]}"
    fi
}

do_enable() {
    local i=$1 lc="launchctl"
    case "${ITEM_TYPE[$i]}" in
        LoginItem) echo "ログイン項目は常に有効です。"; return ;;
    esac
    need_sudo "${ITEM_TYPE[$i]}" && lc="sudo launchctl"
    if $lc enable "${ITEM_DOMAIN[$i]}/${ITEM_LABEL[$i]}"; then
        $lc bootstrap "${ITEM_DOMAIN[$i]}" "${ITEM_PATH[$i]}" 2>/dev/null
        echo "有効化しました: ${ITEM_LABEL[$i]}"
    else
        echo "失敗しました: ${ITEM_LABEL[$i]}"
    fi
}

do_remove() {
    local i=$1 bk
    printf "「%s」を削除します。削除前にバックアップを作成します。よろしいですか? [y/N]: " "${ITEM_LABEL[$i]}"
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "中止しました。"; return; }
    bk="$(make_backup)"
    echo "バックアップ: $bk"
    case "${ITEM_TYPE[$i]}" in
        LoginItem)
            if osascript -e "tell application \"System Events\" to delete login item \"${ITEM_LABEL[$i]}\"" >/dev/null 2>&1; then
                echo "削除しました: ${ITEM_LABEL[$i]}"
            else
                echo "失敗しました: ${ITEM_LABEL[$i]}"
            fi
            ;;
        UserAgent)
            launchctl bootout "${ITEM_DOMAIN[$i]}/${ITEM_LABEL[$i]}" 2>/dev/null
            rm -f "${ITEM_PATH[$i]}" && echo "削除しました: ${ITEM_PATH[$i]}"
            ;;
        GlobalAgent|Daemon)
            sudo launchctl bootout "${ITEM_DOMAIN[$i]}/${ITEM_LABEL[$i]}" 2>/dev/null
            sudo rm -f "${ITEM_PATH[$i]}" && echo "削除しました: ${ITEM_PATH[$i]}"
            ;;
    esac
}

pick_index() {
    # $1=入力番号。妥当なら0始まりのインデックスをechoし0を返す
    case "$1" in (*[!0-9]*|'') return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le ${#ITEM_LABEL[@]} ] || return 1
    echo "$(($1 - 1))"
}

# ============================================================
# メイン
# ============================================================
echo "StartupManager for macOS v$VERSION (完全オフライン動作)"

case "${1:-}" in
    --selftest)
        run_selftest
        exit 0
        ;;
    --backup)
        collect
        echo "バックアップ: $(make_backup)"
        exit 0
        ;;
    --export)
        [ -n "${2:-}" ] || { echo "出力ファイルを指定してください (例: --export items.csv)"; exit 1; }
        collect
        export_csv "$2"
        exit 0
        ;;
    --list|-l)
        collect
        show_list
        exit 0
        ;;
esac

collect
show_list
echo "コマンド: d <番号>=無効化  e <番号>=有効化  r <番号>=削除  b=バックアップ作成  s=復元  c=CSV出力  l=再表示  q=終了"
while true; do
    printf "> "
    read -r cmd arg || break
    case "$cmd" in
        q|Q) break ;;
        l|L) collect; show_list ;;
        b|B) echo "バックアップ: $(make_backup)" ;;
        c|C) export_csv "${arg:-$SCRIPT_DIR/StartupItems_$(date +%Y%m%d).csv}" ;;
        s|S) restore_menu; collect ;;
        d|D) idx="$(pick_index "${arg:-}")" && do_disable "$idx" && collect || echo "番号を指定してください (例: d 3)" ;;
        e|E) idx="$(pick_index "${arg:-}")" && do_enable "$idx" && collect || echo "番号を指定してください (例: e 3)" ;;
        r|R) idx="$(pick_index "${arg:-}")" && { do_remove "$idx"; collect; } || echo "番号を指定してください (例: r 3)" ;;
        '') ;;
        *) echo "不明なコマンドです。d/e/r <番号>, b, s, l, q" ;;
    esac
done
echo "終了しました。"
