@testable import AISwitchCore
import Foundation
import Testing

struct ClaudeSettingsBinderTests {
    let root = makeTempDir("proj with space")
    let binder: ClaudeSettingsBinder

    init() {
        binder = ClaudeSettingsBinder(helperPath: "/Applications/Project AI'Switch.app/Contents/Helpers/aiswitch-key-helper",
                                      managedSettingsPaths: [], userSettingsPath: "/nonexistent/settings.json")
    }

    var settingsPath: String { root + "/.claude/settings.local.json" }

    @Test func appliesIdempotentlyAndPreservesOtherSettings() throws {
        writeJSON(["permissions": ["allow": ["Bash(ls)"]], "env": ["FOO": "bar"]], to: settingsPath)
        let first = try binder.apply(profile: sampleProfile, folder: root, previous: nil)
        #expect(first.changed)
        let json = try #require(readJSON(settingsPath))
        #expect((json["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        let env = try #require(json["env"] as? [String: String])
        #expect(env["FOO"] == "bar")
        #expect(env["ANTHROPIC_BASE_URL"] == "https://litellm.example.test")
        #expect(env["ANTHROPIC_MODEL"] == "claude-alpha")
        #expect(env["ANTHROPIC_API_KEY"] == "" && env["ANTHROPIC_AUTH_TOKEN"] == "")
        #expect((json["apiKeyHelper"] as? String)?.hasSuffix("credential --profile \(sampleProfile.id.uuidString)") == true)

        let bytes = FileManager.default.contents(atPath: settingsPath)
        let second = try binder.apply(profile: sampleProfile, folder: root, previous: first.binding)
        #expect(!second.changed)
        #expect(second.binding == first.binding)
        #expect(FileManager.default.contents(atPath: settingsPath) == bytes)
        #expect(binder.inspect(first.binding, profile: sampleProfile).health == .active)
    }

    @Test func helperCommandSurvivesSpacesAndQuotesInPath() throws {
        let dir = makeTempDir("helper dir's")
        let helper = dir + "/aiswitch-key-helper"
        try "#!/bin/sh\nprintf 'ok:%s' \"$3\"\n".write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        let command = try #require(ClaudeSettingsBinder(helperPath: helper, managedSettingsPaths: []).desiredValues(for: sampleProfile)["apiKeyHelper"])
        let out = makeTempDir() + "/out"
        #expect(sh("\(command) > '\(out)'", in: root) == 0)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "ok:\(sampleProfile.id.uuidString)")
    }

    @Test func foreignValuesAreConflictsAndLeftUntouched() throws {
        writeJSON(["apiKeyHelper": "/usr/local/bin/other-helper", "env": ["ANTHROPIC_API_KEY": "sk-user"]], to: settingsPath)
        let before = FileManager.default.contents(atPath: settingsPath)
        #expect(throws: AISwitchError.self) { try binder.apply(profile: sampleProfile, folder: root, previous: nil) }
        #expect(FileManager.default.contents(atPath: settingsPath) == before)
        do { _ = try binder.apply(profile: sampleProfile, folder: root, previous: nil) } catch let AISwitchError.settingsConflicts(conflicts) {
            #expect(conflicts.count == 2)
            #expect(!conflicts.map(\.message).joined().contains("sk-user"))
        }
    }

    @Test func switchingProfileReplacesOnlyOwnValues() throws {
        let a = try binder.apply(profile: sampleProfile, folder: root, previous: nil)
        let b = try binder.apply(profile: otherProfile, folder: root, previous: a.binding)
        let env = try #require(readJSON(settingsPath)?["env"] as? [String: String])
        #expect(env["ANTHROPIC_BASE_URL"] == "https://litellm-b.example.test")
        #expect(env["ANTHROPIC_MODEL"] == nil)
        #expect(b.binding.id == a.binding.id && b.binding.profileID == otherProfile.id)
    }

    @Test func userEditedValueBlocksReapplyAndSurvivesRevert() throws {
        let a = try binder.apply(profile: sampleProfile, folder: root, previous: nil)
        var json = try #require(readJSON(settingsPath))
        var env = json["env"] as! [String: Any]
        env["ANTHROPIC_MODEL"] = "user-choice"
        json["env"] = env
        json["model"] = "opus"
        writeJSON(json, to: settingsPath)
        #expect(binder.inspect(a.binding, profile: sampleProfile).health == .drifted(["env.ANTHROPIC_MODEL"]))
        #expect(throws: AISwitchError.self) { try binder.apply(profile: sampleProfile, folder: root, previous: nil) }

        let kept = try binder.revert(a.binding)
        #expect(kept == ["env.ANTHROPIC_MODEL"])
        let after = try #require(readJSON(settingsPath))
        #expect(after["apiKeyHelper"] == nil)
        #expect(after["model"] as? String == "opus")
        #expect(after["env"] as? [String: String] == ["ANTHROPIC_MODEL": "user-choice"])
    }

    @Test func revertDeletesFileCreatedOnlyForTheBinding() throws {
        let a = try binder.apply(profile: sampleProfile, folder: root, previous: nil)
        #expect(try binder.revert(a.binding).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: settingsPath))
        #expect(!FileManager.default.fileExists(atPath: root + "/.claude"))
        #expect(binder.inspect(a.binding, profile: sampleProfile).health == .notApplied)
    }

    @Test func invalidJSONIsNotOverwritten() throws {
        try FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        try "{ broken".write(toFile: settingsPath, atomically: true, encoding: .utf8)
        #expect(throws: AISwitchError.self) { try binder.apply(profile: sampleProfile, folder: root, previous: nil) }
        #expect(try String(contentsOfFile: settingsPath, encoding: .utf8) == "{ broken")
    }

    @Test func missingFolderStatus() {
        let binding = WorkspaceBinding(path: root + "/gone", profileID: sampleProfile.id)
        #expect(binder.inspect(binding, profile: sampleProfile).health == .folderMissing)
        #expect(throws: AISwitchError.folderNotFound(root + "/gone")) { try binder.apply(profile: sampleProfile, folder: root + "/gone", previous: nil) }
    }

    @Test func managedSettingsAndProviderSwitchesBlock() throws {
        let managed = makeTempDir() + "/managed-settings.json"
        writeJSON(["apiKeyHelper": "/opt/corp/helper"], to: managed)
        let user = makeTempDir() + "/settings.json"
        writeJSON(["env": ["CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_API_KEY": "x"]], to: user)
        let strict = ClaudeSettingsBinder(helperPath: "/h", managedSettingsPaths: [managed], userSettingsPath: user)
        let conflicts = strict.environmentConflicts(root: root)
        #expect(conflicts.filter { $0.severity == .blocking }.count == 2)
        #expect(conflicts.filter { $0.severity == .warning }.count == 1)
        #expect(throws: AISwitchError.self) { try strict.apply(profile: sampleProfile, folder: root, previous: nil) }
        #expect(!FileManager.default.fileExists(atPath: settingsPath))
    }
}

struct GitIntegrationTests {
    let binder = ClaudeSettingsBinder(helperPath: "/h", managedSettingsPaths: [], userSettingsPath: "/nonexistent")

    @Test func subfoldersAndWorktreesResolveToMainRoot() throws {
        let repo = makeTempDir("repo")
        gitInit(repo)
        try FileManager.default.createDirectory(atPath: repo + "/sub/deep", withIntermediateDirectories: true)
        let worktree = (repo as NSString).deletingLastPathComponent + "/repo wt"
        sh("git worktree add -q --detach '\(worktree)'", in: repo)
        #expect(ClaudeSettingsBinder.settingsRoot(for: repo + "/sub/deep") == repo)
        #expect(ClaudeSettingsBinder.settingsRoot(for: worktree) == repo)
        #expect(throws: AISwitchError.notSettingsRoot(folder: repo + "/sub", root: repo)) {
            try binder.apply(profile: sampleProfile, folder: repo + "/sub", previous: nil)
        }
        let plain = makeTempDir("plain")
        #expect(ClaudeSettingsBinder.settingsRoot(for: plain) == plain)
    }

    @Test func gitExcludeAddedOnceAndRemovedOnRevert() throws {
        let repo = makeTempDir("repo")
        gitInit(repo)
        let first = try binder.apply(profile: sampleProfile, folder: repo, previous: nil)
        #expect(first.binding.gitExcludeEntry == ClaudeSettingsBinder.gitExcludeLine)
        #expect(sh("git check-ignore -q .claude/settings.local.json", in: repo) == 0)
        #expect(sh("test -z \"$(git status --porcelain)\"", in: repo) == 0)
        let second = try binder.apply(profile: sampleProfile, folder: repo, previous: first.binding)
        #expect(second.binding.gitExcludeEntry == ClaudeSettingsBinder.gitExcludeLine)
        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.components(separatedBy: ClaudeSettingsBinder.gitExcludeLine).count == 2)
        try binder.revert(second.binding)
        #expect(!(try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)).contains(ClaudeSettingsBinder.gitExcludeLine))
    }

    @Test func trackedLocalSettingsBlock() throws {
        let repo = makeTempDir("repo")
        gitInit(repo)
        writeJSON(["model": "opus"], to: repo + "/.claude/settings.local.json")
        sh("git add -f .claude/settings.local.json && git -c user.email=t@t -c user.name=t commit -qm add", in: repo)
        #expect(throws: AISwitchError.self) { try binder.apply(profile: sampleProfile, folder: repo, previous: nil) }
    }
}
