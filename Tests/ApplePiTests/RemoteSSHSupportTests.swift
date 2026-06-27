import Foundation
import Testing
@testable import ApplePi

/// Covers the environment-variable allowlist that `RemoteSSHSupport`
/// applies when it hands a child process to `Process`.
///
/// The pre-hardening implementation propagated the entire parent process
/// environment, which meant anything a developer happened to have
/// exported in their shell (`OPENAI_API_KEY`, `GITHUB_TOKEN`, AWS
/// credentials, …) silently rode along to the `pi` agent and, in remote
/// mode, onto the SSH target host. These tests pin the new behaviour: a
/// small, explicit allowlist is the source of truth, everything else is
/// dropped, and the result never contains a parent-supplied secret.
@Suite("RemoteSSHSupport — process environment allowlist")
struct RemoteSSHSupportTests {

    @Test
    func processEnvironmentDropsParentSecrets() {
        let parent: [String: String] = [
            "PATH": "/usr/bin",
            "HOME": "/Users/ada",
            "USER": "ada",
            "OPENAI_API_KEY": "sk-parent-leak",
            "GITHUB_TOKEN": "ghp_parentleak",
            "AWS_ACCESS_KEY_ID": "AKIAPARENTLEAK",
            "AWS_SECRET_ACCESS_KEY": "leaky",
            "PI_CODING_AGENT_DIR": "/Users/ada/.pi/agent"
        ]

        let env = RemoteSSHSupport.processEnvironment(parentEnvironment: parent)

        // The allowlisted keys survive.
        #expect(env["HOME"] == "/Users/ada")
        #expect(env["USER"] == "ada")
        #expect(env["PATH"]?.hasSuffix("/usr/bin") == true)
        // The default PATH from the helper is prepended.
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)

        // The non-allowlisted secret keys are dropped.
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["GITHUB_TOKEN"] == nil)
        #expect(env["AWS_ACCESS_KEY_ID"] == nil)
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)

        // The exact set of returned keys is the allowlist, plus PATH
        // (which is always overridden with the helper default). Allow
        // PATH to be the only key that might not be from the parent.
        let expectedKeys = Set(RemoteSSHSupport.allowlistedEnvironmentKeys)
        #expect(Set(env.keys).isSubset(of: expectedKeys))
    }

    @Test
    func processEnvironmentIncludesAllStandardAllowlistedKeys() {
        let parent: [String: String] = [
            "HOME": "/Users/ada",
            "USER": "ada",
            "LOGNAME": "ada",
            "PATH": "/usr/bin",
            "TMPDIR": "/var/folders/abc/T/",
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
            "XDG_RUNTIME_DIR": "/run/user/501"
        ]

        let env = RemoteSSHSupport.processEnvironment(parentEnvironment: parent)

        for key in RemoteSSHSupport.allowlistedEnvironmentKeys where key != "PATH" {
            #expect(env[key] == parent[key], "expected \(key) to be forwarded verbatim from the parent")
        }
        // PATH is forwarded but the helper always prepends its own
        // defaults so the child can find Homebrew-installed `pi` etc.
        #expect(env["PATH"]?.hasSuffix("/usr/bin") == true)
    }

    @Test
    func processEnvironmentReplacesEmptyHomeAndUserWithDefaults() {
        let parent: [String: String] = [
            "HOME": "",
            "USER": "",
            "PATH": "/usr/bin"
        ]

        let env = RemoteSSHSupport.processEnvironment(parentEnvironment: parent)

        // The empty values from the parent are not forwarded; HOME and
        // USER get a sensible default so `~` expansion and `$USER` lookups
        // inside the child process keep working.
        #expect(env["HOME"]?.isEmpty == false)
        #expect(env["USER"]?.isEmpty == false)
    }

    @Test
    func processEnvironmentAlwaysPrependsLocalPathDefault() {
        // Even when the parent supplies no PATH, the child still gets a
        // sane PATH so that `pi` (or `ssh`) can resolve tools like
        // `/usr/bin/env` itself.
        let env = RemoteSSHSupport.processEnvironment(parentEnvironment: [:])

        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }

    @Test
    func processEnvironmentDoesNotLeakVariablesOutsideTheAllowlist() {
        // Random parent-side state that must not survive the filter.
        let parent: [String: String] = [
            "PATH": "/usr/bin",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "LD_PRELOAD": "/tmp/evil.so",
            "PYTHONPATH": "/tmp/evil",
            "NODE_OPTIONS": "--require /tmp/evil.js",
            "BASH_ENV": "/tmp/evil.sh",
            "ENV": "/tmp/evil.sh",
            "EDITOR": "vim",
            "PAGER": "less",
            "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.abc/Listeners",
            "GPG_AGENT_INFO": "/tmp/gpg",
            "API_TOKEN_1": "leak1",
            "PI_TEST_SECRET": "leak2"
        ]

        let env = RemoteSSHSupport.processEnvironment(parentEnvironment: parent)

        for key in parent.keys where !RemoteSSHSupport.allowlistedEnvironmentKeys.contains(key) {
            #expect(env[key] == nil, "parent variable \(key) must not reach the child")
        }
    }

    @Test
    func remoteEnvironmentStillExposesAskpassAndPasswordFile() {
        let host = PiHostConfiguration(
            mode: .remoteSSH,
            agentDirectory: "~/.pi/agent",
            remoteHost: "pi.example.com",
            remotePort: 22,
            remoteUser: "ada",
            remotePiExecutable: "pi",
            remoteAuthMethod: .password
        )
        // A leaked secret that must be filtered.
        let parent: [String: String] = [
            "PATH": "/usr/bin",
            "HOME": "/Users/ada",
            "OPENAI_API_KEY": "sk-parent-leak"
        ]

        let env = RemoteSSHSupport.remoteEnvironment(
            for: host,
            askpassExecutable: "/Applications/pi-app.app/Contents/Resources/pi-app-askpass",
            parentEnvironment: parent
        )

        // The askpass plumbing is wired up …
        #expect(env["SSH_ASKPASS"] == "/Applications/pi-app.app/Contents/Resources/pi-app-askpass")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["DISPLAY"] == ":0")
        // … and the parent's secret still does not leak.
        #expect(env["OPENAI_API_KEY"] == nil)
    }
}
