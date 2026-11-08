---
name: mac-thermal-dev
description: Mac の温度・ファン・SMC・IOHID センサーを扱う Swift コードを書く / 直す時に読む。AppleSMC の 80 バイト構造体とコマンド番号、Apple Silicon の IOHIDEventSystemClient 温度読み取り、ファンキー (FNum/F0Ac/F0Tg/F0Md/Ftst) と thermalmonitord のアンロック手順、機種差 (M1/M4/M5)、root が要る操作と要らない操作の線引き、既知の落とし穴を示す。Trigger: SMC, AppleSMC, IOHID, 温度センサー, ファン制御, fan, thermalmonitord, Ftst, ThermalPilot, thermalctl, 熱い, サーマル。
---

# Mac 温度・ファン開発 Skill

## まず確認すること

1. 対象は Apple Silicon か Intel か (`#if arch(arm64)`)。読み方が根本的に違う。
2. 操作は **読み取り** (root 不要) か **書き込み** (root 必須) か。
3. 配布形態: ad-hoc 署名なら `SMAppService` 特権ヘルパーは動かない → osascript の管理者認証で代替。

## 温度の読み取り

- **Apple Silicon**: `IOHIDEventSystemClient` (非公開 API。`dlsym` で取る)。
  Matching `{"PrimaryUsagePage": 0xff00, "PrimaryUsage": 5}` → `CopyServices` → 各 service の `Product` が名前、
  `IOHIDServiceClientCopyEvent(svc, 15, 0, 0)` → `IOHIDEventGetFloatValue(ev, 15 << 16)` が ℃。
  0 以下・150 超は捨てる。名前の例: `PMU tdie1..8` (CPU), `GPU MTR Temp Sensor*`, `NAND CH0 temp`, `gas gauge battery`。
- **Intel**: SMC `TC0P` `TC0D` `TG0P` `TM0P` `TH0P` `TB0T` (型 `sp78`)。
- **フォールバック (Apple Silicon の SMC)**: `Tp01`〜`Tp16` (`flt `), `Tg0*`。
- `powermetrics --samplers smc` は Apple Silicon で使えない。`ProcessInfo.thermalState` は公開 API で全機種 OK。

## AppleSMC

- サービス `AppleSMC` の子 `AppleSMCKeysEndpoint` を `IOServiceOpen`。`IOConnectCallStructMethod(conn, 2, &in, 80, &out, &80)`。
- `data8`: 5=read, 6=write, 8=keyFromIndex, 9=keyInfo。`result`: 0x84=キー無し, 0x82=書き込み拒否。
- 構造体は **80 バイト**。Swift はネスト構造体の末尾パディングを詰めるので keyInfo (u32,u32,u8) はフラットに展開しパディングを明示。`precondition(MemoryLayout<SMCKeyData>.size == 80)` を入れる。
- 型: `flt ` = LE float32 / `fpe2` = BE 14.2 固定小数 (÷4) / `sp78` = BE 7.8 符号付き (÷256) / `ui8 ` `ui16` `ui32` = BE 整数。
- 参照実装: `Sources/ThermalCore/SMC.swift` (本リポジトリ), vladkens/macmon `src/sources.rs`。

## ファン

| キー | 型 | 意味 |
|---|---|---|
| `FNum` | ui8 | ファン数 (0 ならファンレス) |
| `F%dAc` | flt (Intel は fpe2) | 実 RPM |
| `F%dTg` | flt | 目標 RPM。**Min/Max で強制されない → 自前で clamp** |
| `F%dMn` `F%dMx` | flt | 推奨範囲 |
| `F%dMd` / `F%dmd` | ui8 | 0 auto / 1 manual / 3 system。**M5 は小文字** → 両方 `hasKey` で探す |
| `Ftst` | ui8 | 診断フラグ。M5 には無い |

書き込み手順 (agoodkind/macos-smc-fan 由来):
1. `F%dMd = 1` を直接書く (M1 / M5 はこれで通る)
2. 0x82 なら `Ftst = 1`
3. 100ms ごとに `F%dMd = 1` を再試行、最大 10 秒 (M4 はこれが必要)
4. `F%dTg = rpm`
5. 復帰: `F%dMd = 0`、他に手動ファンが無ければ `Ftst = 0`

落とし穴:
- thermalmonitord は数秒で制御を取り戻す → 継続制御はループで再設定し続ける (`thermalctl curve`)。
- スリープ復帰で `Ftst` はリセット。
- 0 rpm まで落とせるのは OS だけ。十分冷えたら auto に返す。
- **Linux でビルドが通っても macOS で通るとは限らない**。例: `fork()` は Swift on Darwin では unavailable (Glibc では使える)。この CLI は Linux CI でビルドされるが、Darwin 固有の可否はユーザーの Mac でしか確認できない。新しい API を足す時は、既に Mac でビルド済みの API を優先し、確認できていないことを明言する。
- **置換スクリプトは一致件数を検証する**。Python の `str.replace` は不一致でも黙って何もしない。過去に「反映した」と報告した変更が実際には入っていなかった。
- 診断ログ: thermalctl は root 時のみ `/var/log/thermalctl.log`、アプリは `~/Library/Logs/ThermalPilot.log`。原因が推測の段階では修正を主張せず、まずログで確認する。
- **2026-11-08 Apple M1 実機で確認済み**: アプリの「ファン全開」(osascript の前面実行) と、停止ファイルによるパスワード無しの「自動に戻す」。未確認: `--parent` によるアプリ終了時の停止、`curve`、Intel と M2〜M5。
- **アプリから root の boost をパスワード無しで止める**には停止ファイルを使う (`--stop-file PATH`)。一般ユーザーは root にシグナルを送れない。アプリが作成・削除し、root は `fileExists` で存在を確かめるだけ (root が利用者のパスを書き込み・削除すると、シンボリックリンクで悪用されうるため)。確認間隔 0.1 秒、Linux の再現テストで反応は最大 0.1 秒。
- **boost / curve は長時間ループ**。`auto` は必ず先に `BackgroundFanController.stop()` で止める (止めないと 2 秒後に再設定されて「戻らない」バグになる)。アプリからは `/usr/bin/osascript` を子プロセスで起動し、`do shell script ... with administrator privileges` の**前面**で boost を実行する。同じ admin の `do shell script` 配下で `nohup ... &` を使うと thermalctl が一度も起動しなかった (2026-11 実機ログ: AppleScript は成功、thermalctl のログもプロセスも無し)。前面実行は最初の版でファンを保持できていた。
- M2 / M3 は未検証。実機で `thermalctl keys F` を見てから書く。

## 権限と配布

- 読み取り全部・`ps`・`ProcessInfo.thermalState`・`kill` (自分のプロセス): root 不要。
- SMC 書き込み・`pmset -a lowpowermode`: root。ad-hoc 署名アプリは `NSAppleScript("do shell script ... with administrator privileges")` で都度認証。
- Developer ID があるなら `SMAppService.daemon` + XPC ヘルパー (FanBar / smctl / agoodkind 方式) に移行する。
- IOHIDEventSystemClient は非公開 API → Mac App Store 不可。

## このリポジトリの約束

- SwiftPM 単体 (Xcode プロジェクト無し)。外部依存を足さない。macOS 14+、Observation / MenuBarExtra。
- 純粋ロジックは `ThermalCore` の IOKit 非依存部分に置き、`swift test` でテストする。
- 古い API を書かない: `kIOMasterPortDefault` ではなく `kIOMainPortDefault`、`ObservableObject` ではなく `@Observable`、`onChange(of:) { _, _ in }` の 2 引数形。
- UI 文言は日本語。遊び心のある一言 (`ThermalLevel.mood`) は残す。

## 関連 Skills (GitHub)

- rshankras/claude-code-apple-skills: `/plugin marketplace add rshankras/claude-code-apple-skills` → `/plugin install apple-skills@indie-apple-stack` (SwiftUI / Swift 6 / 配布)
- anthropics/skills: Skill の書式仕様 (`spec/`)
