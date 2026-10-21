import Foundation
import Testing
@testable import VNCCore

private let testSuiteName = "MiniVNC.tests"

/// One shared defaults suite with a unique key per test, so at most one preferences file ever exists.
private func withTemporaryKey(_ body: (UserDefaults, String) -> Void) {
    let defaults = UserDefaults(suiteName: testSuiteName)!
    let key = "savedConnections.\(UUID())"
    defer { defaults.removeObject(forKey: key) }
    body(defaults, key)
}

struct ConnectionStoreTests {
    private let office = SavedConnection(name: "Office", host: "office.local", port: 5900)
    private let lab = SavedConnection(name: "Lab", host: "::1", port: 5901)
    private let nas = SavedConnection(name: "", host: "nas", port: 22)

    @Test func startsEmpty() {
        withTemporaryKey { defaults, key in
            #expect(ConnectionStore(defaults: defaults, key: key).connections.isEmpty)
        }
    }

    @Test func addsInInsertionOrder() {
        withTemporaryKey { defaults, key in
            let store = ConnectionStore(defaults: defaults, key: key)
            store.save(office)
            store.save(lab)
            store.save(nas)
            #expect(store.connections == [office, lab, nas])
            #expect(store.connection(id: lab.id) == lab)
            #expect(store.connection(id: UUID()) == nil)
        }
    }

    @Test func updatesInPlaceKeepingOrder() {
        withTemporaryKey { defaults, key in
            let store = ConnectionStore(defaults: defaults, key: key)
            store.save(office)
            store.save(lab)
            store.save(nas)
            var edited = lab
            edited.name = "Lab 2"
            edited.port = 5902
            store.save(edited)
            #expect(store.connections == [office, edited, nas])
            #expect(ConnectionStore(defaults: defaults, key: key).connections == [office, edited, nas])
        }
    }

    @Test func deletes() {
        withTemporaryKey { defaults, key in
            let store = ConnectionStore(defaults: defaults, key: key)
            store.save(office)
            store.save(lab)
            store.delete(id: office.id)
            store.delete(id: UUID())
            #expect(store.connections == [lab])
            #expect(store.connection(id: office.id) == nil)
            #expect(ConnectionStore(defaults: defaults, key: key).connections == [lab])
        }
    }

    @Test func persistsAcrossInstances() {
        withTemporaryKey { defaults, key in
            let store = ConnectionStore(defaults: defaults, key: key)
            store.save(office)
            store.save(nas)
            #expect(ConnectionStore(defaults: defaults, key: key).connections == [office, nas])
        }
    }

    @Test func usesTheGivenKey() {
        withTemporaryKey { defaults, a in
            withTemporaryKey { _, b in
                ConnectionStore(defaults: defaults, key: a).save(office)
                #expect(ConnectionStore(defaults: defaults, key: b).connections.isEmpty)
                #expect(ConnectionStore(defaults: defaults, key: a).connections == [office])
                #expect(defaults.data(forKey: a) != nil)
            }
        }
    }

    @Test func defaultKeyIsSavedConnections() {
        let defaults = UserDefaults(suiteName: testSuiteName)!
        defaults.removeObject(forKey: "savedConnections")
        defer { defaults.removeObject(forKey: "savedConnections") }
        ConnectionStore(defaults: defaults).save(office)
        #expect(ConnectionStore(defaults: defaults, key: "savedConnections").connections == [office])
    }

    @Test func invalidJSONLoadsAsEmptyAndIsOverwrittenOnSave() {
        withTemporaryKey { defaults, key in
            defaults.set(Data("not json".utf8), forKey: key)
            let store = ConnectionStore(defaults: defaults, key: key)
            #expect(store.connections.isEmpty)
            store.save(office)
            #expect(ConnectionStore(defaults: defaults, key: key).connections == [office])
        }
    }

    @Test func nonDataValueLoadsAsEmpty() {
        withTemporaryKey { defaults, key in
            defaults.set("a string, not data", forKey: key)
            #expect(ConnectionStore(defaults: defaults, key: key).connections.isEmpty)
        }
    }

    @Test func wrongJSONShapeLoadsAsEmpty() {
        withTemporaryKey { defaults, key in
            defaults.set(Data(#"[{"name": "missing fields"}]"#.utf8), forKey: key)
            #expect(ConnectionStore(defaults: defaults, key: key).connections.isEmpty)
        }
    }

    @Test func displayNameFallsBackToFormattedAddress() {
        #expect(office.displayName == "Office")
        #expect(nas.displayName == "nas::22")
        #expect(SavedConnection(name: "  \n", host: "::1", port: 5901).displayName == "[::1]:5901")
        #expect(SavedConnection(name: "", host: "mac.local", port: 5900).displayName == "mac.local:5900")
    }

    @Test func keychainLabelNamesTheConnectionAndAddress() {
        #expect(office.keychainLabel == "MiniVNC: Office (office.local:5900)")
        #expect(nas.keychainLabel == "MiniVNC: nas::22")
    }
}
