import Foundation
import Testing
@testable import Work42PluginKit

private nonisolated struct LegacyOnly: WidgetPermissionService {
    func status(_ permission: PluginPermission) async throws -> PluginPermissionStatus { .granted }
    func request(_ permission: PluginPermission) async throws -> PluginPermissionStatus { .notAsked }
}

private nonisolated struct ByID: WidgetPermissionByIDService {
    func status(id: PluginPermissionID, target: String?) async throws -> PluginPermissionStatus {
        id == .contacts ? .denied : id == .localNetwork ? .unsupported : .notDeclared
    }
    func request(id: PluginPermissionID, target: String?) async throws -> PluginPermissionStatus {
        target == "~/Documents" ? .granted : .notAsked
    }
}

@Suite("Permissions by id")
struct PluginPermissionByIDServiceTests {

    @Test("a host that knows only the four of 3.3.0 answers those by id and names the rest as unsupported by the host")
    func legacyHost() async throws {
        let service: any WidgetPermissionService = LegacyOnly()
        #expect(try await service.status(id: .microphone) == .granted)
        #expect(try await service.request(id: .speechRecognition) == .notAsked)
        await #expect(throws: WidgetServiceError.self) { _ = try await service.status(id: .contacts) }
        await #expect(throws: WidgetServiceError.self) { _ = try await service.request(id: .camera) }
    }

    @Test("a 3.5.0 host answers every id, with the target of a per-target permission")
    func idHost() async throws {
        let service: any WidgetPermissionService = ByID()
        #expect(try await service.status(id: .contacts) == .denied)
        #expect(try await service.status(id: .localNetwork) == .unsupported)
        #expect(try await service.status(id: .photos) == .notDeclared)
        #expect(try await service.request(id: .filesAndFolders, target: "~/Documents") == .granted)
        #expect(try await service.request(id: .filesAndFolders, target: "~/Desktop") == .notAsked)
    }

    @Test("unsupported survives the wire as its own word")
    func wire() throws {
        let data = try JSONEncoder().encode([PluginPermissionStatus.unsupported])
        #expect(String(decoding: data, as: UTF8.self) == "[\"unsupported\"]")
        #expect(try JSONDecoder().decode([PluginPermissionStatus].self, from: data) == [.unsupported])
    }
}
