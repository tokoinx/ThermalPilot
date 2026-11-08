// swift-tools-version: 5.10
// ThermalPilot — Mac の温度を「見える化」して、熱くなったら冷やす手を打つメニューバーアプリ。
//
// ターゲット構成
//   ThermalCore   : センサー読み取り (IOHID / AppleSMC)・判定ロジック・プロセス計測 (ライブラリ)
//   ThermalPilot  : SwiftUI MenuBarExtra アプリ本体 (macOS 14+)
//   thermalctl    : ターミナル用 CLI。センサー表示と、オプトインのファン制御 (root 必要)
//   ThermalCoreTests : 純粋ロジックのユニットテスト (IOKit 非依存)

import PackageDescription

// SwiftUI / AppKit を使うアプリ本体は macOS でしかビルドできない。
// Linux (CI や Claude Code のクラウド環境) では ThermalCore と thermalctl、テストだけを対象にする。
#if os(macOS)
let appProducts: [Product] = [.executable(name: "ThermalPilot", targets: ["ThermalPilot"])]
let appTargets: [Target] = [
    .executableTarget(
        name: "ThermalPilot",
        dependencies: ["ThermalCore"],
        path: "Sources/ThermalPilot",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("UserNotifications"),
        ]
    ),
]
#else
let appProducts: [Product] = []
let appTargets: [Target] = []
#endif

let package = Package(
    name: "ThermalPilot",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v14),
    ],
    products: appProducts + [
        .executable(name: "thermalctl", targets: ["thermalctl"]),
        .library(name: "ThermalCore", targets: ["ThermalCore"]),
    ],
    targets: appTargets + [
        .target(
            name: "ThermalCore",
            path: "Sources/ThermalCore",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "thermalctl",
            dependencies: ["ThermalCore"],
            path: "Sources/thermalctl"
        ),
        .testTarget(
            name: "ThermalCoreTests",
            dependencies: ["ThermalCore"],
            path: "Tests/ThermalCoreTests"
        ),
    ]
)
