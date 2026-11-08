import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerConfigurationTests {
    @Test func aMissingRuntimeDirectoryIsRefused() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }

        #expect(throws: ServerConfiguration.Failure.missingRuntimeDirectory) {
            try ServerConfiguration.resolve(environment: ["HOME": scratch.root], executableDirectory: scratch.bin)
        }
    }

    @Test(arguments: ["relative/run", "/no/such/run"])
    func anUnusableRuntimeDirectoryIsRefused(runtime: String) throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }

        #expect(throws: ServerConfiguration.Failure.unusableRuntimeDirectory(runtime)) {
            try ServerConfiguration.resolve(environment: ["XDG_RUNTIME_DIR": runtime], executableDirectory: scratch.bin)
        }
    }

    @Test func zmxAndResourcesDefaultBesideTheExecutable() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }

        let configuration = try scratch.configuration()

        #expect(configuration.zmxPath == scratch.zmx)
        #expect(configuration.resourcesDirectory == scratch.bin + "/resources")
        #expect(configuration.catalogName == "testbox")
    }

    @Test func aMissingZmxIsRefused() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }

        #expect(throws: ServerConfiguration.Failure.missingZmx(scratch.root + "/none")) {
            try ServerConfiguration.resolve(zmxPath: scratch.root + "/none", environment: scratch.environment,
                                            executableDirectory: scratch.bin)
        }
    }

    @Test func theStateDirectoryComesFromTheArgumentThenTheEnvironmentThenTheDefault() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        var environment = scratch.environment
        environment["AGTERM_STATE_DIR"] = scratch.root + "/from-env"

        let argument = try ServerConfiguration.resolve(stateDirectory: scratch.state, environment: environment,
                                                       executableDirectory: scratch.bin)
        let fromEnvironment = try ServerConfiguration.resolve(environment: environment, executableDirectory: scratch.bin)
        let fallback = try ServerConfiguration.resolve(environment: scratch.environment, executableDirectory: scratch.bin)

        #expect(argument.stateDirectory == scratch.state)
        #expect(fromEnvironment.stateDirectory == scratch.root + "/from-env")
        #expect(fallback.stateDirectory == ControlResolve.defaultStateDirectory(environment: scratch.environment))
    }

    // regression: a relative state directory was exported as is, so a pane in another directory missed the socket
    @Test func aRelativeStateDirectoryResolvesAgainstTheWorkingDirectory() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        var environment = scratch.environment
        environment["AGTERM_STATE_DIR"] = "env-state"

        let argument = try ServerConfiguration.resolve(stateDirectory: "alt-state/../alt-state", environment: scratch.environment,
                                                       executableDirectory: scratch.bin, workingDirectory: scratch.root)
        let fromEnvironment = try ServerConfiguration.resolve(environment: environment, executableDirectory: scratch.bin,
                                                              workingDirectory: scratch.root)

        #expect(argument.stateDirectory == scratch.root + "/alt-state")
        #expect(fromEnvironment.stateDirectory == scratch.root + "/env-state")
    }

    @Test func theSocketAndTheZmxSocketsLiveWhereTheyBelong() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }

        let configuration = try scratch.configuration()

        #expect(configuration.socketPath == scratch.state + "/agterm.sock")
        #expect(configuration.zmxSocketDirectory.hasPrefix(scratch.runtime + "/agterm-zmx-"))
    }
}
