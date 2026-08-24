// DataService.swift
//
// Manages the data/ sub-directory of a manuscript: CSV import (stored as SQLite),
// image import, and SQL query execution.
//
// The caller passes the manuscript's resolved `data/` directory (see
// `PersistenceService.dataDirectory(for:)`), which already accounts for
// user-chosen folders vs the default App Support location.  Custom folders are
// writable through the security-scoped bookmark the store resolves on load.
//
// SQLite3 C API is used directly via `import SQLite3`.  Every table created by
// this service is named "data" and every column maps to a CSV header cell.
// Column names are normalised (spaces → underscores, stripped to alphanumerics)
// to make hand-written SQL ergonomic.

import Foundation
import SQLite3
import AppKit              // NSImage for image import check

// MARK: - Errors

enum DataServiceError: LocalizedError {
    case emptyFile
    case csvParseFailed(String)
    case sqliteOpenFailed(String)
    case sqliteExecFailed(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:              return "The file is empty."
        case .csvParseFailed(let m):  return "CSV parse error: \(m)"
        case .sqliteOpenFailed(let m): return "Could not open database: \(m)"
        case .sqliteExecFailed(let m): return "Query failed: \(m)"
        case .fileNotFound(let m):    return "File not found: \(m)"
        }
    }
}

// MARK: - QueryResult

/// The tabular result of executing a SQL query.
struct QueryResult: Sendable {
    let columns: [String]
    let rows: [[String]]         // each inner array aligns with `columns`
    let errorMessage: String?    // non-nil when the query failed

    static let empty = QueryResult(columns: [], rows: [], errorMessage: nil)
    static func error(_ msg: String) -> QueryResult {
        QueryResult(columns: [], rows: [], errorMessage: msg)
    }
}

// MARK: - DataService

/// Stateless helper that manages CSV → SQLite storage and query execution.
struct DataService: Sendable {

    // MARK: - CSV Import

    /// Parses a CSV file, creates a SQLite database, and returns a ready `DataAsset`.
    ///
    /// - Parameters:
    ///   - sourceURL:     URL of the CSV file chosen by the user.
    ///   - dataDirectory: The manuscript's resolved `data/` directory.
    /// - Returns: A fully configured `DataAsset` ready to be stored in the manuscript.
    /// - Throws: `DataServiceError` on parse or SQLite failures.
    func importCSV(from sourceURL: URL, into dataDirectory: URL) throws -> DataAsset {
        // Excel and other tools often export non-UTF-8 CSVs — try the common
        // encodings before giving up.
        let data = try Data(contentsOf: sourceURL)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw DataServiceError.csvParseFailed("Unsupported text encoding — save the file as UTF-8 CSV and retry.")
        }

        let assetID = UUID()
        let dbFileName = "\(assetID.uuidString).sqlite"
        let dbURL = dataDirectory.appendingPathComponent(dbFileName)
        try buildDatabase(from: text, at: dbURL, dataStartRow: 2)

        // Keep the original CSV beside the database so "data starts at row
        // N" can rebuild the table later without re-importing.
        try? Data(text.utf8).write(
            to: dataDirectory.appendingPathComponent("\(assetID.uuidString).csv"), options: .atomic)

        let name = sourceURL.deletingPathExtension().lastPathComponent
        return DataAsset(
            id: assetID,
            name: name,
            type: .csv,
            fileName: dbFileName,
            importedAt: Date(),
            lastQuery: "SELECT * FROM data"
        )
    }

    /// True when the asset's original CSV was kept (imports since Aug 2026)
    /// — the precondition for re-fitting the data start row.
    func hasSourceCSV(for asset: DataAsset, dataDirectory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: dataDirectory.appendingPathComponent("\(asset.id.uuidString).csv").path)
    }

    /// Rebuilds the asset's SQLite table from its kept CSV with the data
    /// starting at `dataStartRow` (1-based; the header is the row above).
    func refitCSV(asset: DataAsset, dataStartRow: Int, dataDirectory: URL) throws {
        let csvURL = dataDirectory.appendingPathComponent("\(asset.id.uuidString).csv")
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            throw DataServiceError.fileNotFound("The original CSV was not kept for this asset — re-import it to change the start row.")
        }
        let text = try String(contentsOf: csvURL, encoding: .utf8)
        let dbURL = dataDirectory.appendingPathComponent(asset.fileName)
        try buildDatabase(from: text, at: dbURL, dataStartRow: dataStartRow)
    }

    /// Parses CSV text and (re)creates the SQLite table: rows before the
    /// header (the row above `dataStartRow`) are skipped as preamble.
    private func buildDatabase(from text: String, at dbURL: URL, dataStartRow: Int) throws {
        let parsed = parseCSV(text)
        guard !parsed.isEmpty else { throw DataServiceError.emptyFile }

        let skip = max(dataStartRow, 2) - 2
        guard parsed.count > skip else {
            throw DataServiceError.csvParseFailed("The file has only \(parsed.count) rows — can't start data at row \(dataStartRow).")
        }
        let header = parsed[skip]
        let dataRows = Array(parsed.dropFirst(skip + 1))

        // SQLite tables cap at 2000 columns; a count anywhere near that almost
        // always means the file didn't parse as expected.
        guard header.count <= 2000 else {
            throw DataServiceError.csvParseFailed(
                "The header parsed to \(header.count) columns (SQLite supports 2000). Check the file's delimiter and quoting.")
        }

        do {
            try createSQLiteTable(at: dbURL, columns: header, rows: dataRows)
        } catch {
            // A failed CREATE leaves a 0-byte .sqlite behind (sqlite3_open
            // touches the file before the schema commits) — don't orphan it.
            try? FileManager.default.removeItem(at: dbURL)
            throw error
        }
    }

    // MARK: - Image Import

    /// Copies an image file into the data directory and returns a `DataAsset`.
    func importImage(from sourceURL: URL, into dataDirectory: URL) throws -> DataAsset {
        let ext = sourceURL.pathExtension.lowercased()
        let assetID = UUID()
        let fileName = "\(assetID.uuidString).\(ext)"
        let dest = dataDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        let name = sourceURL.deletingPathExtension().lastPathComponent
        return DataAsset(
            id: assetID,
            name: name,
            type: .image,
            fileName: fileName,
            importedAt: Date(),
            lastQuery: ""
        )
    }

    // MARK: - Query Execution

    /// Executes a SQL SELECT statement against the asset's SQLite database.
    ///
    /// Returns `QueryResult.error(...)` rather than throwing so the UI can
    /// display inline error messages without crashing.
    func runQuery(_ sql: String, asset: DataAsset, dataDirectory: URL) -> QueryResult {
        let dbURL = dataDirectory.appendingPathComponent(asset.fileName)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return .error("Database file not found.")
        }
        do {
            return try executeSQLQuery(sql, dbURL: dbURL)
        } catch let e as DataServiceError {
            return .error(e.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Returns the column names for a CSV asset's SQLite table.
    func columns(for asset: DataAsset, dataDirectory: URL) -> [String] {
        let result = runQuery("SELECT * FROM data LIMIT 1", asset: asset, dataDirectory: dataDirectory)
        return result.columns
    }

    // MARK: - CSV Parsing

    /// RFC 4180-compliant CSV parser.
    /// Returns an array of rows; the first row is the header.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false

        // CRLF must be normalised BEFORE splitting into Characters: "\r\n" is a
        // single Swift grapheme cluster, so it matches neither the "\r" nor the
        // "\n" case below and every Windows/Excel row break would be swallowed
        // into the field — globbing the whole file into one giant row.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(c)
                }
            } else {
                switch c {
                case "\"" where currentField.isEmpty:
                    // A quote only OPENS a quoted field at the field's start
                    // (RFC 4180).  A stray mid-field quote (5'10", O"Brien…)
                    // must stay literal — treating it as an opener swallows
                    // newlines and globs the rest of the file into one row.
                    inQuotes = true
                case "\"":
                    currentField.append(c)
                case ",":
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                case "\r":
                    if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    fallthrough
                case "\n":
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                    if !currentRow.allSatisfy({ $0.isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                default:
                    currentField.append(c)
                }
            }
            i += 1
        }
        // Flush the last field / row.
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
            if !currentRow.allSatisfy({ $0.isEmpty }) {
                rows.append(currentRow)
            }
        }
        return rows
    }

    // MARK: - SQLite helpers

    /// Normalises a CSV header cell into a safe SQLite column name.
    /// Spaces become underscores; non-alphanumeric characters are dropped.
    private func sanitiseColumnName(_ name: String) -> String {
        let base = name
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return base.isEmpty ? "col" : base
    }

    /// Creates (or recreates) a SQLite database with a single "data" table.
    private func createSQLiteTable(at dbURL: URL, columns: [String], rows: [[String]]) throws {
        if FileManager.default.fileExists(atPath: dbURL.path) {
            try FileManager.default.removeItem(at: dbURL)
        }
        var db: OpaquePointer?
        let openRC = sqlite3_open(dbURL.path, &db)
        defer { sqlite3_close(db) }
        guard openRC == SQLITE_OK else {
            throw DataServiceError.sqliteOpenFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Sanitized headers can collide (repeated headers, case-only
        // differences — SQLite names are case-insensitive, or symbols stripped
        // to the same base).  Suffix duplicates: AL, AL_2, AL_3 …
        var safeColumns: [String] = []
        var seen: [String: Int] = [:]
        for raw in columns {
            let base = sanitiseColumnName(raw)
            let count = (seen[base.lowercased()] ?? 0) + 1
            seen[base.lowercased()] = count
            safeColumns.append(count == 1 ? base : "\(base)_\(count)")
        }
        // Infer column affinity so ORDER BY sorts numbers numerically: a
        // column whose every non-empty value parses as a number is REAL,
        // otherwise TEXT.  (SQLite coerces the bound strings on insert.)
        let colDefs = safeColumns.enumerated().map { index, name in
            let numeric = rows.allSatisfy { row in
                guard row.indices.contains(index) else { return true }
                let value = row[index]
                return value.isEmpty || Double(value.replacingOccurrences(of: ",", with: "")) != nil
            }
            return "\"\(name)\" \(numeric ? "REAL" : "TEXT")"
        }.joined(separator: ", ")
        let createSQL = "CREATE TABLE IF NOT EXISTS data (\(colDefs));"
        var errMsg: UnsafeMutablePointer<Int8>?
        let createRC = sqlite3_exec(db, createSQL, nil, nil, &errMsg)
        if createRC != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DataServiceError.sqliteExecFailed(msg)
        }

        for row in rows {
            let padded = padRow(row, to: safeColumns.count)
            let placeholders = Array(repeating: "?", count: safeColumns.count).joined(separator: ", ")
            let colList = safeColumns.map { "\"\($0)\"" }.joined(separator: ", ")
            let insertSQL = "INSERT INTO data (\(colList)) VALUES (\(placeholders));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            for (idx, value) in padded.enumerated() {
                // Bind numeric-looking values as doubles (comma separators
                // stripped) so REAL columns actually sort numerically; SQLite
                // stores a "1,234" bound as text even in a REAL column.
                let stripped = value.replacingOccurrences(of: ",", with: "")
                if !value.isEmpty, let number = Double(stripped) {
                    sqlite3_bind_double(stmt, Int32(idx + 1), number)
                } else {
                    // SQLITE_TRANSIENT: SQLite copies the string immediately. A nil
                    // destructor (SQLITE_STATIC) would promise the buffer outlives
                    // the statement, which a bridged temporary can't guarantee.
                    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(stmt, Int32(idx + 1), value, -1, SQLITE_TRANSIENT)
                }
            }
            sqlite3_step(stmt)
        }
    }

    /// Executes a SELECT query and returns the result set.
    private func executeSQLQuery(_ sql: String, dbURL: URL) throws -> QueryResult {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard openRC == SQLITE_OK else {
            throw DataServiceError.sqliteOpenFailed(String(cString: sqlite3_errmsg(db)))
        }
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepRC == SQLITE_OK else {
            throw DataServiceError.sqliteExecFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = (0..<columnCount).map { i in
            String(cString: sqlite3_column_name(stmt, Int32(i)))
        }
        if columns.isEmpty { columns = [] }

        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row = (0..<columnCount).map { i -> String in
                if let ptr = sqlite3_column_text(stmt, Int32(i)) {
                    return String(cString: ptr)
                }
                return ""
            }
            rows.append(row)
        }
        return QueryResult(columns: columns, rows: rows, errorMessage: nil)
    }

    /// Pads (or truncates) a row to exactly `count` elements.
    private func padRow(_ row: [String], to count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}
