import Foundation

let count = 100_000
let entries = (0..<count).map { ArchiveEntry(name: "root/dir\($0 / 1000)/file\($0).txt", isDirectory: false, size: 10) }
let treeStart = ProcessInfo.processInfo.systemUptime
let tree = Node.buildTree(entries)
var nodes: [Node] = []; tree.flatten(into: &nodes)
print(String(format: "100,000 entries: tree + flatten %.4f s (%d nodes)", ProcessInfo.processInfo.systemUptime - treeStart, nodes.count))
let small = Array(entries.prefix(10_000))
let validationStart = ProcessInfo.processInfo.systemUptime
try ArchiveSafety.validateEntries(small)
print(String(format: "10,000 entries: validate metadata %.4f s", ProcessInfo.processInfo.systemUptime - validationStart))
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("preflight-output")
let preflightStart = ProcessInfo.processInfo.systemUptime
try ArchiveSafety.validateDestination(destination.path, entries: small)
print(String(format: "10,000 entries: validate destination %.4f s", ProcessInfo.processInfo.systemUptime - preflightStart))
let token = TaskCancellation(); token.cancel()
let cancelStart = ProcessInfo.processInfo.systemUptime
do { try ArchiveSafety.validateDestination(destination.path, entries: small, cancelled: { token.cancelled }); fatalError("Cancellation ignored") }
catch { print(String(format: "Preflight cancellation %.4f s", ProcessInfo.processInfo.systemUptime - cancelStart)) }
let query = ArchiveQuery("type:file ext:txt size>1B -backup")
let queryStart = ProcessInfo.processInfo.systemUptime
let matches = entries.filter { query.matches(path: $0.name, size: $0.size, modified: $0.mtime, directory: $0.isDirectory) }
print(String(format: "100,000 entries: advanced query %.4f s (%d matches)", ProcessInfo.processInfo.systemUptime - queryStart, matches.count))
let mapStart = ProcessInfo.processInfo.systemUptime
let map = try ArchiveMap.build(entries)
print(String(format: "100,000 entries: archive map %.4f s (%d rendered largest rows)", ProcessInfo.processInfo.systemUptime - mapStart, map.largest.count))
let exportStart = ProcessInfo.processInfo.systemUptime
let records = try ArchiveInventory.records(entries: entries)
let csv = try ArchiveInventory.data(records, format: .csv)
print(String(format: "100,000 entries: inventory + CSV %.4f s (%d bytes)", ProcessInfo.processInfo.systemUptime - exportStart, csv.count))

let coverageStart = ProcessInfo.processInfo.systemUptime
let selectionRoots = Node.selectionRoots(nodes)
precondition(selectionRoots.count == 1 && selectionRoots[0].path == "root")
print(String(format: "100,101 selected nodes: coverage %.4f s (%d roots)", ProcessInfo.processInfo.systemUptime - coverageStart, selectionRoots.count))
let leaves = nodes.filter { !$0.isDir }
let leafStart = ProcessInfo.processInfo.systemUptime
let leafRoots = Node.selectionRoots(leaves)
precondition(leafRoots.count == count)
print(String(format: "100,000 selected files: coverage + totals %.4f s (%lld bytes)", ProcessInfo.processInfo.systemUptime - leafStart, leafRoots.reduce(Int64(0)) { $0 + $1.totalSize }))
let summaryStart = ProcessInfo.processInfo.systemUptime
let workspace = WorkspaceModel()
workspace.update(ArchiveInfo(path: destination.path, kind: .other, details: "", entries: entries))
var summaryTotal: Int64 = 0
for _ in 0..<10_000 { summaryTotal += workspace.archiveTotalSize }
precondition(summaryTotal == 10_000_000_000)
print(String(format: "100,000 entries: summary + 10,000 reads %.4f s", ProcessInfo.processInfo.systemUptime - summaryStart))
let selectiveQuery = ArchiveQuery("file type:file ext:txt size>1KB")
let selectiveStart = ProcessInfo.processInfo.systemUptime
let selectiveMatches = entries.filter { selectiveQuery.matches(path: $0.name, size: $0.size, modified: $0.mtime, directory: $0.isDirectory) }
print(String(format: "100,000 entries: rejecting metadata query %.4f s (%d matches)", ProcessInfo.processInfo.systemUptime - selectiveStart, selectiveMatches.count))
