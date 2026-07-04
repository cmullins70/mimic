import Testing
import Foundation
@testable import VFSCore

@Test func createWriteReadRoundtrip() async throws {
    let fs = InMemoryFS()
    let p = try RemotePath("/hello.txt")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("hello world".utf8))
    let data = try await fs.read(file: p, offset: 6, length: 5)
    #expect(String(decoding: data, as: UTF8.self) == "world")
    let attrs = try await fs.attributes(at: p)
    #expect(attrs.size == 11)
    #expect(attrs.type == .file)
}

@Test func readPastEOFReturnsShortData() async throws {
    let fs = InMemoryFS()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("abc".utf8))
    let data = try await fs.read(file: p, offset: 1, length: 100)
    #expect(data.count == 2)
}

@Test func listAndMkdirAndErrors() async throws {
    let fs = InMemoryFS()
    try await fs.createDirectory(at: try RemotePath("/docs"))
    try await fs.createFile(at: try RemotePath("/docs/a.txt"))
    let entries = try await fs.list(directory: try RemotePath("/docs"))
    #expect(entries.map(\.name) == ["a.txt"])

    await #expect(throws: RemoteFSError.notFound(try RemotePath("/nope"))) {
        _ = try await fs.list(directory: try RemotePath("/nope"))
    }
    await #expect(throws: RemoteFSError.alreadyExists(try RemotePath("/docs"))) {
        try await fs.createDirectory(at: try RemotePath("/docs"))
    }
    await #expect(throws: RemoteFSError.directoryNotEmpty(try RemotePath("/docs"))) {
        try await fs.removeDirectory(at: try RemotePath("/docs"))
    }
}

@Test func renameMovesSubtree() async throws {
    let fs = InMemoryFS()
    try await fs.createDirectory(at: try RemotePath("/a"))
    try await fs.createFile(at: try RemotePath("/a/f"))
    try await fs.rename(from: try RemotePath("/a"), to: try RemotePath("/b"))
    _ = try await fs.attributes(at: try RemotePath("/b/f"))
    await #expect(throws: RemoteFSError.notFound(try RemotePath("/a"))) {
        _ = try await fs.attributes(at: try RemotePath("/a"))
    }
}

@Test func truncateShrinksAndGrows() async throws {
    let fs = InMemoryFS()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("abcdef".utf8))
    try await fs.truncate(file: p, to: 3)
    #expect(try await fs.attributes(at: p).size == 3)
    try await fs.truncate(file: p, to: 5)
    let d = try await fs.read(file: p, offset: 0, length: 10)
    #expect(d == Data("abc".utf8) + Data([0, 0]))
}
