import Darwin
import Dispatch
import Foundation
import iFocusCore
import iFocusMac

@main
struct IFocusCLI {
    static let version = "0.1.0"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            exitWithFlush(MainActor.assumeIsolated { AppController.runAgentCommand() })
        }

        switch arguments[0] {
        case "--version", "-v":
            guard arguments.count == 1 else {
                exitWithFlush(usageError("Unexpected arguments after \(arguments[0])"))
            }
            print("ifocus \(version)")
            exitWithFlush(0)

        case "--help", "-h":
            printHelp()
            exitWithFlush(0)

        case "--run":
            guard arguments.count == 1 else {
                exitWithFlush(usageError("Unexpected arguments after --run"))
            }
            exitWithFlush(MainActor.assumeIsolated { AppController.runAgentCommand() })

        case "--calibrate":
            guard arguments.count == 1 else {
                exitWithFlush(usageError("Unexpected arguments after --calibrate"))
            }
            exitWithFlush(MainActor.assumeIsolated { AppController.runCalibrateCommand() })

        case "--doctor":
            var focusTest = false
            for arg in arguments.dropFirst() {
                if arg == "--focus-test" {
                    focusTest = true
                } else {
                    exitWithFlush(usageError("Unknown option for --doctor: \(arg)"))
                }
            }
            let runFocusTest = focusTest
            Task {
                let code = await Doctor.run(focusTest: runFocusTest)
                fflush(stdout)
                fflush(stderr)
                Darwin.exit(code)
            }
            dispatchMain()

        case "--simulate":
            exitWithFlush(runSimulate(arguments: Array(arguments.dropFirst())))

        default:
            exitWithFlush(usageError("Unknown command or option: \(arguments[0])"))
        }
    }

    private static func exitWithFlush(_ code: Int32) -> Never {
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(code)
    }

    private static func runSimulate(arguments: [String]) -> Int32 {
        var target = "all"
        var targetSpecified = false
        var seed: UInt64 = 1
        var verbose = false

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--verbose":
                verbose = true
            case "--seed":
                i += 1
                guard i < arguments.count, let parsed = UInt64(arguments[i]) else {
                    return usageError("--seed requires an unsigned integer")
                }
                seed = parsed
            default:
                if arg.hasPrefix("-") || targetSpecified {
                    return usageError("Unexpected argument for --simulate: \(arg)")
                }
                target = arg
                targetSpecified = true
            }
            i += 1
        }

        let scenarios: [Scenario]
        switch target {
        case "desk-three":
            scenarios = [Scenario.deskThree60s()]
        case "dual-external":
            scenarios = [
                Scenario.dualExternalMultiMonitorTour(),
                Scenario.dualExternalSwitchBeforeTyping(),
                Scenario.dualExternalTypingThenQuiet(),
                Scenario.dualExternalFlyover(),
                Scenario.dualExternalTypeTooSoon(),
            ]
        case "mixed-apps":
            scenarios = [
                Scenario.mixedAppsTour(),
                Scenario.mixedAppsTypingWhileReading(),
            ]
        case "all":
            scenarios = [
                Scenario.deskThree60s(),
                Scenario.dualExternalMultiMonitorTour(),
                Scenario.dualExternalSwitchBeforeTyping(),
                Scenario.dualExternalTypingThenQuiet(),
                Scenario.dualExternalFlyover(),
                Scenario.dualExternalTypeTooSoon(),
                Scenario.mixedAppsTour(),
                Scenario.mixedAppsTypingWhileReading(),
            ]
        default:
            return usageError("Unknown simulate scenario '\(target)'. Expected desk-three, dual-external, mixed-apps, or all.")
        }

        var allPassed = true
        let config = Config()

        for scenario in scenarios {
            switch ScenarioRunner.run(scenario, seed: seed, config: config) {
            case .failure(let err):
                fputs("[\(scenario.name)] calibration failed: \(err.description)\n", stderr)
                allPassed = false
            case .success(let result):
                print("Scenario '\(result.scenarioName)' (seed=\(seed)): \(result.passed ? "PASS" : "FAIL")")
                print("  Expected switches: \(result.expectedSwitches)")
                print("  Actual switches:   \(result.actualSwitches)")
                for sw in result.switchTimestamps {
                    print(String(format: "  [t=%6.2fs] focus -> window %u", sw.timestamp, sw.windowID))
                }
                if verbose {
                    for entry in result.decisionLog {
                        let vetoStr = entry.veto?.rawValue ?? "-"
                        let candStr = entry.candidateWindowID.map(String.init) ?? "-"
                        print(String(format: "    t=%6.2fs action=%@ veto=%@ cand=%@", entry.timestamp, "\(entry.action)", vetoStr, candStr))
                    }
                }
                if !result.passed {
                    allPassed = false
                }
            }
        }

        return allPassed ? 0 : 1
    }

    private static func usageError(_ message: String) -> Int32 {
        fputs("Error: \(message)\n", stderr)
        printHelp(toStderr: true)
        return 64
    }

    private static func printHelp(toStderr: Bool = false) {
        let text = """
        Usage:
          ifocus [--run]
          ifocus --calibrate
          ifocus --doctor [--focus-test]
          ifocus --simulate [desk-three|dual-external|mixed-apps|all] [--seed N] [--verbose]
          ifocus --version
          ifocus --help
        """
        if toStderr {
            fputs(text + "\n", stderr)
        } else {
            print(text)
        }
    }
}
