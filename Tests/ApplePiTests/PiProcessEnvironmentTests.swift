import Foundation
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

@Suite("PiProcessEnvironment")
struct PiProcessEnvironmentTests {
    @Test func filtersSecretsFromParentEnvironment() {
        let parent = [
            "HOME": "/Users/ada",
            "USER": "ada",
            "PATH": "/custom/bin",
            "OPENAI_API_KEY": "secret",
            "GITHUB_TOKEN": "secret"
        ]

        let env = PiProcessEnvironment.processEnvironment(parentEnvironment: parent)

        #expect(env["HOME"] == "/Users/ada")
        #expect(env["USER"] == "ada")
        #expect(env["PATH"]?.contains("/custom/bin") == true)
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["GITHUB_TOKEN"] == nil)
    }

    @Test func guaranteesHomeUserAndDefaultPath() {
        let env = PiProcessEnvironment.processEnvironment(parentEnvironment: [:])

        #expect(env["HOME"]?.isEmpty == false)
        #expect(env["USER"]?.isEmpty == false)
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }
}
