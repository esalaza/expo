//  Copyright © 2019 650 Industries. All rights reserved.

import Foundation
import SQLite3

@objc
enum EXUpdatesDatabaseUtilsError: Int, Error {
  case SQLitePrepareError
  case SQLiteArgsBindError
  case SQLiteBlobNotUUID
  case SQLiteGetResultsError
}

// these are not exported in the swift headers
let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public extension UUID {
  var data: Data {
    return withUnsafeBytes(of: self.uuid, { Data($0) })
  }
}

/**
 * Utility class with methods for common database functions used across multiple classes.
 */
@objcMembers
public final class EXUpdatesDatabaseUtils {
  public static func execute(sql: String, withArgs args: [Any?]?, onDatabase db: OpaquePointer) throws -> [[String: Any?]] {
    var stmt: OpaquePointer? = nil
    guard sqlite3_prepare_v2(db, String(sql.utf8), -1, &stmt, nil) == SQLITE_OK,
      let stmt = stmt else {
      throw EXUpdatesDatabaseUtilsError.SQLitePrepareError
    }
    
    if let args = args {
      guard bind(statement: stmt, withArgs: args) else {
        throw EXUpdatesDatabaseUtilsError.SQLiteArgsBindError
      }
    }
    
    var rows: [[String: Any?]] = []
    var columnNames: [String] = []
    
    var columnCount: Int32 = 0
    var didFetchColumns = false
    var result: Int32
    var hasMore = true
    var didError = false
    
    while hasMore {
      result = sqlite3_step(stmt)
      switch result {
      case SQLITE_ROW:
        if !didFetchColumns {
          // get all column names once at the beginning
          columnCount = sqlite3_column_count(stmt)
          
          for i in 0..<columnCount {
            columnNames.append(String(utf8String: sqlite3_column_name(stmt, Int32(i)))!)
          }
          
          didFetchColumns = true
        }
        
        var entry: [String: Any] = [:]
        for i in 0..<columnCount {
          let columnValue = try getValue(withStatement: stmt, column: i)
          entry[columnNames[Int(i)]] = columnValue
        }
        rows.append(entry)
      case SQLITE_DONE:
        hasMore = false
      default:
        didError = true
        hasMore = false
      }
    }
    
    sqlite3_finalize(stmt)
    
    if didError {
      throw EXUpdatesDatabaseUtilsError.SQLiteGetResultsError
    }
    
    return rows
  }
  
  private static func bind(statement stmt: OpaquePointer, withArgs args: [Any?]) -> Bool {
    for (index, arg) in args.enumerated() {
      let bindIdx = Int32(index + 1)
      switch arg {
      case let arg as UUID:
        guard withUnsafeBytes(of: arg.uuid, { bufferPointer -> Int32 in
          sqlite3_bind_blob(stmt, bindIdx, bufferPointer.baseAddress, 16, SQLITE_TRANSIENT)
        }) == SQLITE_OK else {
          return false
        }
      case let arg as NSNumber:
        guard sqlite3_bind_int64(stmt, bindIdx, arg.int64Value) == SQLITE_OK else {
          return false
        }
      case let arg as Date:
        let dateValue = arg.timeIntervalSince1970 * 1000
        guard sqlite3_bind_int64(stmt, bindIdx, Int64(dateValue)) == SQLITE_OK else {
          return false
        }
      case let arg as [AnyHashable: Any]:
        guard let jsonData = try? JSONSerialization.data(withJSONObject: arg) else {
          return false
        }
        guard withUnsafeBytes(of: jsonData, { bufferPointer -> Int32 in
          sqlite3_bind_text(stmt, bindIdx, bufferPointer.baseAddress, Int32(jsonData.count), SQLITE_TRANSIENT)
        }) == SQLITE_OK else {
          return false
        }
      case nil:
        guard sqlite3_bind_null(stmt, bindIdx) == SQLITE_OK else {
          return false
        }
      default:
        // convert to string
        var string: String
        if let arg = arg as? String {
          string = arg
        } else {
          string = (arg as! NSObject).description
        }
        let data = string.data(using: .utf8)!
        guard withUnsafeBytes(of: data, { bufferPointer -> Int32 in
          sqlite3_bind_text(stmt, bindIdx, bufferPointer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }) == SQLITE_OK else {
          return false
        }
      }
    }
    return true
  }
  
  private static func getValue(withStatement stmt: OpaquePointer, column: Int32) throws -> Any? {
    let columnType = sqlite3_column_type(stmt, column)
    switch columnType {
    case SQLITE_INTEGER:
      return sqlite3_column_int64(stmt, column)
    case SQLITE_FLOAT:
      return sqlite3_column_double(stmt, column)
    case SQLITE_BLOB:
      guard sqlite3_column_bytes(stmt, column) == 16 else {
        throw EXUpdatesDatabaseUtilsError.SQLiteBlobNotUUID
      }
      let blob = Data(bytes: sqlite3_column_blob(stmt, column), count: 16)
      return blob.withUnsafeBytes { rawBytes -> UUID in
        NSUUID(uuidBytes: rawBytes) as UUID
      }
    case SQLITE_TEXT:
      return String(cString: sqlite3_column_text(stmt, column))
    default:
      return nil
    }
  }
  
  public static func errorMessage(fromSqlite db: OpaquePointer) -> String {
    let code = sqlite3_errcode(db)
    let extendedCode = sqlite3_extended_errcode(db)
    let message = String(utf8String: sqlite3_errmsg(db))
    return String(format: "Error code %i: %@ (extended error code %i)", [code, message!, extendedCode])
  }
  
  public static func date(fromUnixTimeMilliseconds number: Int) -> Date {
    return Date(timeIntervalSince1970: Double(number) / 1000)
  }
}

