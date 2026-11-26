// PluginPermissionIDTests.swift — a permission by its plugin.yaml name (SDK 3.5.0, WOR-893).

import Foundation
import Testing

@testable import Work42PluginKit

@Suite("PluginPermissionID")
struct PluginPermissionIDTests {

    @Test("every legacy permission converts to the id with the same name")
    func legacyConversion() {
        for permission in PluginPermission.allCases {
            #expect(PluginPermissionID(permission).rawValue == permission.rawValue)
        }
        #expect(PluginPermissionID.systemAudio == PluginPermissionID(.systemAudio))
        #expect(PluginPermissionID.speechRecognition.rawValue == "speech-recognition")
    }

    @Test("an id is its name on the wire, and a name this SDK does not list survives a round trip")
    func codableIsTheBareName() throws {
        let encoded = try JSONEncoder().encode(["id": PluginPermissionID.fullDiskAccess])
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"id":"full-disk-access"}"#)
        let future = try JSONDecoder().decode([String: PluginPermissionID].self, from: Data(#"{"id":"a-permission-from-a-newer-work42"}"#.utf8))
        #expect(future["id"]?.rawValue == "a-permission-from-a-newer-work42")
        #expect(PluginPermissionID(rawValue: "x") == "x")
    }

    @Test("the named ids are distinct")
    func distinct() {
        let all: [PluginPermissionID] = [
            .microphone, .systemAudio, .speechRecognition, .calendars, .reminders, .contacts, .photos, .camera, .location,
            .bluetooth, .localNetwork, .mediaLibrary, .notifications, .filesAndFolders, .automation, .fullDiskAccess,
            .accessibility, .inputMonitoring, .screenRecording, .runCommands,
        ]
        #expect(Set(all).count == all.count)
        #expect(PluginPermissionID.runCommands.rawValue == "run-commands")
    }
}
