import XCTest
@testable import ThermalCore

final class ThermalPolicyTests: XCTestCase {
    let t = ThermalThresholds(warm: 60, hot: 80, critical: 95, hysteresis: 4)

    func testRawLevelBoundaries() {
        XCTAssertEqual(ThermalPolicy.rawLevel(for: 40, thresholds: t), .cool)
        XCTAssertEqual(ThermalPolicy.rawLevel(for: 60, thresholds: t), .warm)
        XCTAssertEqual(ThermalPolicy.rawLevel(for: 79.9, thresholds: t), .warm)
        XCTAssertEqual(ThermalPolicy.rawLevel(for: 80, thresholds: t), .hot)
        XCTAssertEqual(ThermalPolicy.rawLevel(for: 95, thresholds: t), .critical)
    }

    func testHysteresisPreventsFlapping() {
        // 80 で hot に入り、78 ではまだ hot のまま (80 - 4 = 76 を下回るまで下げない)
        var level = ThermalPolicy.level(for: 80, previous: .cool, thresholds: t)
        XCTAssertEqual(level, .hot)
        level = ThermalPolicy.level(for: 78, previous: level, thresholds: t)
        XCTAssertEqual(level, .hot)
        level = ThermalPolicy.level(for: 75.9, previous: level, thresholds: t)
        XCTAssertEqual(level, .warm)
        // 上がる時は即座
        level = ThermalPolicy.level(for: 96, previous: level, thresholds: t)
        XCTAssertEqual(level, .critical)
    }

    func testPressureEscalatesLevel() {
        XCTAssertEqual(ThermalPolicy.level(for: 50, previous: .cool, thresholds: t, pressure: .serious), .hot)
        XCTAssertEqual(ThermalPolicy.level(for: 50, previous: .cool, thresholds: t, pressure: .critical), .critical)
        XCTAssertEqual(ThermalPolicy.level(for: 50, previous: .cool, thresholds: t, pressure: .fair), .cool)
    }

    func testNoTemperatureIsCool() {
        XCTAssertEqual(ThermalPolicy.level(for: nil, previous: .hot, thresholds: t), .cool)
    }

    func testRepresentativePrefersCPU() {
        let readings = [
            SensorReading(rawName: "PMU tdie1", celsius: 71),
            SensorReading(rawName: "GPU", celsius: 88),
            SensorReading(rawName: "NAND CH0 temp", celsius: 45),
        ]
        XCTAssertEqual(ThermalPolicy.representativeTemperature(readings), 71)
        XCTAssertEqual(ThermalPolicy.representativeTemperature([SensorReading(rawName: "GPU", celsius: 88)]), 88)
        XCTAssertNil(ThermalPolicy.representativeTemperature([]))
    }

    func testAdviceMentionsCulprit() {
        let tips = ThermalPolicy.advice(for: .hot, topProcess: ProcessLoad(pid: 1, name: "Chrome Helper", cpuPercent: 140))
        XCTAssertTrue(tips.first?.contains("Chrome Helper") == true)
    }
}

final class SensorNamingTests: XCTestCase {
    func testAppleSiliconHIDNames() {
        XCTAssertEqual(SensorNaming.classify("PMU tdie3").1, .cpu)
        XCTAssertEqual(SensorNaming.classify("PMU tdie3").0, "CPU ダイ 3")
        XCTAssertEqual(SensorNaming.classify("PMU2 tdie7").0, "CPU ダイ 7 (PMU2)")
        XCTAssertEqual(SensorNaming.classify("pACC MTR Temp Sensor8").0, "P コア クラスタ 8")
        XCTAssertEqual(SensorNaming.classify("eACC MTR Temp Sensor0").1, .cpu)
        XCTAssertEqual(SensorNaming.classify("PMGR SOC Die Temp Sensor2").0, "SoC 2")
        XCTAssertEqual(SensorNaming.classify("ISP MTR Temp Sensor5").1, .other)
        XCTAssertTrue(SensorNaming.isNoise("PMU2 tcal"))
        XCTAssertFalse(SensorNaming.isNoise("PMU tdie1"))
        XCTAssertEqual(SensorNaming.classify("GPU MTR Temp Sensor1").1, .gpu)
        XCTAssertEqual(SensorNaming.classify("NAND CH0 temp").1, .storage)
        XCTAssertEqual(SensorNaming.classify("gas gauge battery").1, .battery)
        XCTAssertEqual(SensorNaming.classify("PMU TP3w").1, .power)
    }

    func testIntelSMCKeys() {
        XCTAssertEqual(SensorNaming.classify("TC0P").1, .cpu)
        XCTAssertEqual(SensorNaming.classify("TG0P").1, .gpu)
        XCTAssertEqual(SensorNaming.classify("TB0T").1, .battery)
        XCTAssertEqual(SensorNaming.classify("TH0P").1, .storage)
        XCTAssertEqual(SensorNaming.classify("Tp05").1, .cpu)
        XCTAssertEqual(SensorNaming.classify("XXXX").1, .other)
    }
}

final class SMCCodecTests: XCTestCase {
    func testFloatLittleEndian() {
        // 1234.5 as Float32 LE
        let bytes = withUnsafeBytes(of: Float(1234.5).bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(SMC.decode(bytes: bytes, type: "flt "), 1234.5)
        XCTAssertEqual(SMC.encode(value: 1234.5, type: "flt ", size: 4), bytes)
    }

    func testFixedPointTypes() {
        XCTAssertEqual(SMC.decode(bytes: [0x3A, 0x98], type: "fpe2"), 3750)       // 0x3A98 / 4
        XCTAssertEqual(SMC.decode(bytes: [0x2D, 0x80], type: "sp78"), 45.5)       // 0x2D80 / 256
        XCTAssertEqual(SMC.decode(bytes: [0xFF, 0x00], type: "sp78"), -1.0)
        XCTAssertEqual(SMC.encode(value: 3750, type: "fpe2", size: 2), [0x3A, 0x98])
    }

    func testIntegerTypes() {
        XCTAssertEqual(SMC.decode(bytes: [3], type: "ui8 "), 3)
        XCTAssertEqual(SMC.decode(bytes: [1], type: "flag"), 1)
        XCTAssertEqual(SMC.decode(bytes: [0x01, 0x00], type: "ui16"), 256)
        XCTAssertEqual(SMC.decode(bytes: [0, 0, 0x10, 0], type: "ui32"), 4096)
        XCTAssertEqual(SMC.encode(value: 1, type: "ui8 ", size: 1), [1])
        XCTAssertNil(SMC.decode(bytes: [1, 2], type: "ch8*"))
    }
}

final class FanCurveTests: XCTestCase {
    func testInterpolation() {
        let c = FanCurve.balanced   // 50→0, 65→2200, 80→4000, 95→6500
        XCTAssertEqual(c.rpm(at: 30), 0)
        XCTAssertEqual(c.rpm(at: 50), 0)
        XCTAssertEqual(c.rpm(at: 57.5), 1100, accuracy: 0.001)
        XCTAssertEqual(c.rpm(at: 80), 4000)
        XCTAssertEqual(c.rpm(at: 120), 6500)
    }

    func testUnsortedPointsAreSorted() {
        let c = FanCurve(points: [.init(celsius: 90, rpm: 5000), .init(celsius: 50, rpm: 1000)])
        XCTAssertEqual(c.rpm(at: 70), 3000, accuracy: 0.001)
    }
}

final class SensorDedupeTests: XCTestCase {
    func testDuplicateNamesGetUniqueIDs() {
        let readings = ThermalEngine.uniquelyIdentified([
            ("gas gauge battery", 30.1), ("gas gauge battery", 29.0), ("NAND CH0 temp", 34.0),
        ])
        XCTAssertEqual(Set(readings.map(\.id)).count, 3)
        XCTAssertEqual(readings[0].label, "バッテリー 1")
        XCTAssertEqual(readings[1].label, "バッテリー 2")
        XCTAssertEqual(readings[2].id, "NAND CH0 temp")
        XCTAssertEqual(readings[2].label, "SSD")   // 末尾が数字でない名前は番号なし
    }
}

final class ProcessSamplerTests: XCTestCase {
    func testParsePsOutput() {
        let out = """
          512  87.3 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer)
         9001  12.0 WindowServer
         1234   0.0 idle_thing
          777   3.2 ps
         4321   1.1 kernel_task
        """
        let procs = ProcessSampler.parse(psOutput: out, limit: 5)
        XCTAssertEqual(procs.count, 3)   // 0% と ps 自身は除外される
        XCTAssertEqual(procs[0].pid, 512)
        XCTAssertEqual(procs[0].name, "Google Chrome Helper (Renderer)")
        XCTAssertEqual(procs[0].cpuPercent, 87.3)
        XCTAssertEqual(procs[1].name, "WindowServer")
        XCTAssertEqual(procs[2].name, "kernel_task")
    }
}
