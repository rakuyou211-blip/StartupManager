# 🚀 StartupManager

**「パソコンの電源を入れてから、使えるようになるまでが長い」——その原因、たぶんスタートアップです。**

StartupManager は、PC起動時に勝手に立ち上がるソフトを一覧にして、ワンクリックで
**止める・戻す・消す**ができる小さな相棒です。インストール不要、スクリプト1本。
そして **完全オフライン** で動きます。あなたの起動項目の情報が外に送られることは、一切ありません。

![platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-blue)
![offline](https://img.shields.io/badge/network-100%25%20offline-brightgreen)
![install](https://img.shields.io/badge/install-not%20required-orange)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

> *A tiny, offline, no-install startup manager for Windows & macOS. Disable, re-enable, or remove what launches at boot — reversibly, with automatic backups.*

---

## なぜ作ったか

Windowsのタスクマネージャーにもスタートアップ管理はあります。でも——

- レジストリの`Run`キー、スタートアップフォルダ、タスクスケジューラ、ストアアプリ……**登録場所がバラバラ**で、全部を1画面で見られない
- 「これ何のソフト?」がわからない。**発行元や実行ファイルの場所**がその場で見えない
- アンインストールしたのに**残骸だけ起動しようとして失敗している**項目に気づけない
- 消したあとに「やっぱり戻したい」が効かない

StartupManager は、**タスクマネージャーがカバーする範囲をぜんぶ1画面に集約**して、
しかも**消す前に自動でバックアップ**を取り、いつでも元に戻せるようにしました。

## こんな人へ

- 🐢 起動が重いPCを、リスクなく軽くしたい
- 🧹 ソフトを消したあとの「起動しようとして失敗する幽霊」を掃除したい
- 🔍 「勝手に起動するこのアプリ、何者?」を発行元・場所からその場で調べたい
- 🔒 レジストリ改変ツールに情報を送られたくない(→ 通信ゼロなので安心)
- 🏢 ネットにつながっていない社内PC・オフライン環境で使いたい(→ USBに入れて持ち込むだけ)

---

## 30秒で始める

### Windows 10 / 11

1. 右上の **Code → Download ZIP** でダウンロードして展開
2. **`StartupManager.bat`** をダブルクリック(管理者として起動します)
3. 一覧から選んで **有効化 / 無効化 / 完全削除**。まずは「無効化」だけでも十分効きます

管理者権限なしでも起動できます(その場合、全ユーザー向けの項目だけ操作できません)。

### macOS 〔ベータ / 動作報告募集中〕

1. ZIPを展開し、ターミナルで一度だけ `chmod +x StartupManager.command`
2. **`StartupManager.command`** をダブルクリック(初回は右クリック→「開く」)
3. 番号を入力して操作(`d 3` で3番を無効化、`l` で再表示、`q` で終了)

> ⚠️ **macOS版は現在ベータです。** ロジックとテストは通っていますが、作者はまだ実機での
> 全機能確認が取れていません。まずは `./StartupManager.command --list`(表示のみ)から試し、
> 変更は可逆な「無効化(`d`)」で様子を見てください。うまく動いた/動かなかったの報告は
> [Issues](../../issues) で大歓迎です 🙏

---

## 何ができる?

| できること | 中身 |
|---|---|
| 🗂 **全部まとめて一覧** | レジストリRun・スタートアップフォルダ・タスク・ストアアプリを1画面に。アイコンつき |
| ⏸ **止める / ▶ 戻す** | タスクマネージャーと同じ`StartupApproved`方式。**いつでも元に戻せる可逆操作** |
| 🗑 **消す(保険つき)** | 完全削除の前に**毎回自動バックアップ**。「復元…」ボタンでまるごと書き戻し |
| 🔎 **正体を調べる** | 発行元・実行ファイルの場所・**デジタル署名の有無**・実行中かどうかを表示 |
| 🩹 **残骸を発見** | 実行ファイルが消えている項目を**赤字**で警告。右クリックで一括選択→掃除 |
| ➕ **追加する** | exeを一覧に**ドラッグ&ドロップ**するだけで起動項目に登録 |
| 📤 **書き出す** | 一覧をCSVエクスポート(GUI・コマンドライン両対応) |
| ⌨️ **キー操作** | `F5`更新 / `Ctrl+A`全選択 / `Delete`無効化 / `Enter`詳細 / `F1`ヘルプ |

そのほか:絞り込み検索、列ソート、「この名前をWebで検索」、無効化した日時の表示、
非管理者時の「管理者として再起動」リンク、ウィンドウサイズの記憶、など。

---

## 安心して使うために

- **無効化は完全に可逆です。** Windowsのタスクマネージャーと同じ仕組みなので、いつでも有効化で戻せます
- **完全削除の前には毎回、自動でバックアップ**を作ります(`Backups\日時\` フォルダ)。
  Windowsは「復元…」ボタンからワンクリックで書き戻せます(タスクは元のフォルダ位置まで復元)
- macOSは削除前にplistをバックアップし、**バックアップが取れなかった項目は削除しません**
- **セルフテスト同梱。** `-SelfTest`(Windows)/ `--selftest`(macOS)で、列挙・無効化・削除→復元・
  CSV出力などが正しく動くかを、実項目に触れず自動チェックできます

---

<details>
<summary>📖 詳しい対象・コマンド・注意事項(クリックで展開)</summary>

### Windows：管理対象

| 種類 | 場所 |
|---|---|
| レジストリ Run キー | HKCU / HKLM / HKLM(32bit, Wow6432Node) |
| スタートアップフォルダ | 現在のユーザー / 全ユーザー |
| タスクスケジューラ | ログオン時 / 起動時トリガーのタスク |
| ストアアプリ (UWP) | スタートアップタスク(有効化/無効化のみ) |

### Windows：コマンドライン

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File StartupManager.ps1 -List          # 一覧表示
powershell -NoProfile -ExecutionPolicy Bypass -File StartupManager.ps1 -Export a.csv   # CSV出力
powershell -NoProfile -ExecutionPolicy Bypass -File StartupManager.ps1 -Backup         # バックアップ
powershell -NoProfile -ExecutionPolicy Bypass -File StartupManager.ps1 -SelfTest       # 動作テスト
```

### macOS：管理対象

| 種類 | 場所 |
|---|---|
| エージェント(ユーザー) | `~/Library/LaunchAgents` |
| エージェント(全体) | `/Library/LaunchAgents` |
| デーモン | `/Library/LaunchDaemons`(操作にsudo) |
| ログイン項目 | システム設定の「ログイン項目」(削除のみ / 復元は非対応) |

### macOS：対話コマンド

```
d <番号>=無効化   e <番号>=有効化   r <番号>=削除   i <番号>=詳細(起動場所)
b=バックアップ   s=復元   c=CSV出力   l=再表示   q=終了
```

コマンドラインオプション：`--list` / `--export out.csv` / `--backup` / `--selftest`

### 注意事項

- レジストリやタスクスケジューラ、launchd を変更するツールです。削除前バックアップは自動で作られますが、**利用は自己責任**でお願いします
- ウイルス対策ソフトが、レジストリ/システムを操作するスクリプトとして警告することがあります(誤検知)
- macOS版は実機での全機能検証が未完了のベータです

</details>

---

## オフラインであること

このツールは **OS標準のコマンドだけ**で動きます。外部との通信・追加ダウンロードは一切ありません。
唯一ネットを使うのは、Windows版の右クリック「この名前をWebで検索」を**あなた自身が押したとき**だけ。
ZIPをUSBメモリに入れれば、ネットにつながっていないPCでもそのまま使えます。

## 貢献・フィードバック

バグ報告・要望・「macOSで動いたよ / 動かなかったよ」の一言、どれも歓迎です。
[Issues](../../issues) からお気軽にどうぞ。⭐ Star をいただけると励みになります。

## ライセンス

[MIT License](LICENSE) — 自由に使って、改変して、配ってOKです。
