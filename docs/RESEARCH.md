# 調査レポート: Mac 温度管理アプリの先行事例と Claude Skills (2026-11-08)

GitHub Search API と各リポジトリの README / ソースを直接読んで調べた。GitHub の `/repos` エンドポイントはこのセッションのプロキシで遮断されていたため、スター数は検索 API の値、詳細は raw ソースと Web 取得による。

## 1. 先行プロジェクト (温度監視・ファン制御)

### ティア 1: 定番・大規模

| リポジトリ | ★ | 言語 | 要点 |
|---|---|---|---|
| crystalidea/macs-fan-control | 1,723 | (配布のみ) | 最有名のファン制御。クローズドソース、Issue 管理のみ |
| exelban/stats | (多数) | Swift | メニューバー監視の定番。温度は IOHID + SMC。ファン制御はヘルパー |
| vladkens/macmon | (多数) | Rust | Apple Silicon 向け TUI。**IOHIDEventSystemClient による温度読み取りと SMC 構造体レイアウトの最も読みやすい参照実装** (`src/sources.rs`) |
| macmade/Hot | (多数) | Swift | 温度とスロットリング表示に特化したメニューバーアプリ |
| hholtmann/smcFanControl | (多数) | ObjC | Intel 時代のファン制御の原典。SMC セレクタ・コマンド番号はここ由来 |
| leaperone/smctl | 158 | Swift | 2026 年の新鋭 CLI。ファンカーブ・充電上限。`smctld` を root LaunchDaemon として XPC 経由で動かす。Homebrew 配布、Developer ID 署名 |
| helson-lin/FanBar | 130 | Swift | 2026 年のメニューバー型ファン制御。`SMAppService` 特権ヘルパー + XPC。6 つの冷却モード、カーブ、Raycast 連携。GPL-3.0。**Xcode 26 / Swift 6、SwiftPM 構成**。`.claude/` と `CLAUDE.md` をリポジトリに含む (= Claude Code で開発されている) |

### ティア 2: 研究・小規模だが示唆が大きい

| リポジトリ | ★ | 要点 |
|---|---|---|
| **agoodkind/macos-smc-fan** | 43 | **Apple Silicon でのファン書き込みを初めて体系的に文書化** (MIT)。thermalmonitord が「システムモード (3)」を強制し直接書き込みを拒否 (0x82) すること、`Ftst=1` の診断アンロックで `F0Md=1` が通ること、M1 / M4 / M5 で挙動が違うことを実測。FanBar / smctl はこれを参照 |
| zyvren/FanPilot | 7 | M1〜M5 対応のメニューバー型。名前が本プロジェクトと似ているので注意 |
| hoobnn/fanfan | 8 | macOS 26 対応、Homebrew 配布、中国語コミュニティ |
| ecc521/CoolMyMac | 5 | メニューバー + CLI の二本立て (本プロジェクトと同じ構成) |
| raminsharifi/MacFanControl | 19 | Rust の TUI。kext 無し |
| caseymrm/go-smc | - | Apple Silicon の CPU 温度 SMC キーが `Tp01`〜`Tp16` (flt) であること、Intel は `TC0P` (sp78)、ファンレス機には `F*Ac` が無いことを明記 |

### 2026 年の傾向

- 2025〜2026 年に **Swift 製のメニューバー型ファン制御アプリが 10 本以上** 立ち上がっている (FanBar, FanPilot, fanfan, Vifty, openfan, FanSense, fanctl ×2, CoolMyMac, MacPulse...)。多くが「Macs Fan Control の無料 OSS 代替」を掲げる。
- 共通アーキテクチャは **App → XPC → 特権ヘルパー (root) → AppleSMC**。ヘルパー登録は macOS 13+ の `SMAppService`。
- 差別化軸は (a) 冷却モードのプリセット, (b) ファンカーブ UI, (c) ウィジェット / Raycast / CLI 連携, (d) Homebrew Cask 配布, (e) 多言語 README。
- **事実上の参入障壁は Developer ID 署名** (有料 Apple Developer Program)。agoodkind の README に「Hard requirement」と明記。ad-hoc 署名ではヘルパーが認証できない。

## 2. 技術メモ (実装に使った知見)

### 温度の読み方

| プラットフォーム | 方法 | 権限 | 出典 |
|---|---|---|---|
| Apple Silicon | `IOHIDEventSystemClient` (非公開)。Matching: `PrimaryUsagePage=0xff00`, `PrimaryUsage=5`。`IOHIDServiceClientCopyEvent(svc, 15, 0, 0)` → `IOHIDEventGetFloatValue(ev, 15<<16)`。センサー名は `Product` プロパティ (`PMU tdie1`, `NAND CH0 temp` 等) | 不要 | macmon `sources.rs` L1439-1550 |
| Apple Silicon (フォールバック) | SMC `Tp01`〜`Tp16` (`flt `), `Tg0*` | 不要 | go-smc, oshi |
| Intel | SMC `TC0P` `TC0D` `TG0P` `TM0P` `TH0P` `TB0T` (`sp78`) | 不要 | smcFanControl, SMCKit |
| 共通 | `ProcessInfo.thermalState` (nominal/fair/serious/critical) | 不要 | Apple 公開 API |
| `powermetrics --samplers smc` | **Apple Silicon では SMC サンプラーが使えない** | sudo | mole.fit 解説 |

### SMC 構造体 (80 バイト) とコマンド

```
key u32 | vers(6) | pLimit(16) | keyInfo{dataSize u32, dataType u32, attr u8 + pad3} | result u8 | status u8 | data8 u8 | pad | data32 u32 | bytes[32]
selector 2 (kSMCHandleYPCEvent)  data8: 5=read 6=write 8=keyFromIndex 9=keyInfo
result 0x84 = key not found, 0x82 = write blocked
型: "flt " LE float32 / "fpe2" BE 14.2 / "sp78" BE 7.8 / "ui8 ,ui16,ui32" BE
```

Swift ではネスト構造体の末尾パディングが詰められることがあるため、本実装は keyInfo をフラットに展開して `MemoryLayout.size == 80` を precondition で検査している。

### ファン (agoodkind/macos-smc-fan `docs/research.md`)

| キー | 型 | 意味 |
|---|---|---|
| `FNum` | ui8 | ファン数 |
| `F%dAc` | flt | 実 RPM (読み取り専用) |
| `F%dTg` | flt | 目標 RPM。Min/Max で**強制されない** (自前で clamp 必須) |
| `F%dMn` / `F%dMx` | flt | 推奨最小 / 最大 |
| `F%dMd` / `F%dmd` | ui8 | 0=auto 1=manual 3=system。M5 は小文字 |
| `Ftst` | ui8 | 診断フラグ。M5 には無い |

アンロック手順: `F%dMd=1` を直接 → 0x82 なら `Ftst=1` → 100ms ごとに `F%dMd=1` を再試行 (10 秒) → `F%dTg` 書き込み。復帰は `F%dMd=0` と (最後なら) `Ftst=0`。スリープで `Ftst` はリセット。thermalmonitord は SMC を直接書かず `AppleCLPC` / `ApplePMGR` のプロパティで制御し、アイドル時 4 秒・高負荷時 250ms で監視。

- M1: 直接書き込み可 / M4: `Ftst` 必要 / M5 (Mac17,7): 小文字キー、`Ftst` 無し、直接書き込み可 / M2, M3: 未検証。

## 3. Claude Code Skills のリサーチ

| リポジトリ | ★ | 内容 | 本件との関係 |
|---|---|---|---|
| **rshankras/claude-code-apple-skills** | 870 | Apple プラットフォーム開発用 165 Skills / 23 カテゴリ。`/plugin marketplace add rshankras/claude-code-apple-skills` → `/plugin install apple-skills@indie-apple-stack`。macOS カテゴリ (Tahoe API, AppKit ブリッジ), SwiftUI (data-flow, layout, toolbars), Swift 6.2 / Concurrency, `design/liquid-glass`, `performance/profiling`, テスト系 (tdd-feature, snapshot-test-setup), App Store 系 | **本件に最適**。メニューバー専用 Skill は無いが、SwiftUI / Swift 6 / 配布系がそのまま使える |
| anthropics/skills | 公式 | docx / pdf / pptx / xlsx + `template`, `spec` (Agent Skills 仕様)。`/plugin marketplace add anthropics/skills` | Skill の書式の正。macOS 向けは無し |
| yibie/skills-manager | 463 | Skills を管理するネイティブ macOS アプリ | 参考: Skills 管理 UI |
| amandeepmittal/skillsbar | 29 | **メニューバーで Skills を管理する macOS アプリ** | メニューバーアプリの実装例として参考 |
| Wholiver/swiftui-design-skill | 208 | SwiftUI デザイン規律 (AI っぽい雑さを避ける 6 ルール) | UI 磨き込みに |
| kylehughes/the-unofficial-swift-programming-language-skill | 46 | Swift 言語仕様を Skill 化 | 文法確認 |
| kylehughes/the-unofficial-swift-concurrency-migration-skill | 58 | Swift 6 Concurrency 移行ガイド | strict concurrency 化する時に |
| hmohamed01/swift-development | 62 | Swift iOS/macOS 開発 Skill | 汎用 |
| gamedev-skills/awesome-gamedev-agent-skills | 7,630 | 77 ゲーム開発 Skills (Godot/Unity/Unreal/Phaser...)。**Roblox は含まれない** | ユーザーの Roblox 開発には直接使えないが、Skill の作り方の参考 |

**温度 / SMC / IOKit 専用の Skill は GitHub 上に見つからなかった。** そこで本プロジェクトに `.claude/skills/mac-thermal-dev/SKILL.md` を同梱し、上記の知見 (SMC レイアウト、キー、アンロック手順、落とし穴) を次のセッションでも使えるようにした。

## 4. 本プロジェクトの位置づけ (ビジネス的な見方)

- **レッドオーシャン**: 無料 OSS のファン制御アプリは 2026 年に乱立。単なる「ファン制御」では差別化できない。
- **空いている席**: 「温度が高い **原因** を示して **行動** につなげる」アプリは少ない。FanBar / smctl はファンを回すことに集中しており、プロセス特定・低電力モード連携・提案文は手薄。ThermalPilot はここを主戦場にした。
- **配布コスト**: Developer ID (年 99 USD) を取ると特権ヘルパー化・公証・Homebrew Cask 配布が可能になり、一気に「普通のアプリ」になる。取らない場合は osascript 認証方式 (本実装) が現実解。
- **日本語圏**: 日本語 UI のこの分野の OSS はほぼ無い。README / UI を日本語ファーストにしつつ英語 README を足すと、fanfan (中国語圏) と同じ型で地域コミュニティを取れる。

## 参照 URL

- https://github.com/vladkens/macmon (src/sources.rs)
- https://github.com/agoodkind/macos-smc-fan (README, docs/research.md)
- https://github.com/helson-lin/FanBar
- https://github.com/leaperone/smctl
- https://github.com/rshankras/claude-code-apple-skills
- https://github.com/anthropics/skills
- https://docs.rs/crate/macmon/0.8.0/source/src/sources.rs
- https://docs.rs/crate/whirr/0.3.4/source/src/mac/hid_temp.rs
- https://pkg.go.dev/github.com/caseymrm/go-smc
- https://javadoc.io/static/com.github.oshi/oshi-core/7.3.2/oshi/util/platform/mac/SmcUtil.html
- https://mole.fit/blog/how-to-check-mac-temperature.md
- https://github.com/WHYBBE/SwiftTempBar
- https://awesome.ecosyste.ms/projects/github.com%2Fdkorunic%2Fismc
