//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2019-2022 RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOTestUtils
@testable import RediStack
import XCTest

final class RedisByteDecoderTests: XCTestCase {
    private var decoder = RedisByteDecoder()
    private var allocator = ByteBufferAllocator()
}

// MARK:  Individual Types

extension RedisByteDecoderTests {
    func testErrors() throws {
        XCTAssertNil(try runTest("-ERR"))
        XCTAssertNil(try runTest("-ERR\r"))
        XCTAssertEqual(try runTest("-ERROR\r\n")?.error?.message.contains("ERROR"), true)

        let multiError: (RESPValue?, RESPValue?) = try runTest("-ERROR\r\n-OTHER ERROR\r\n")
        XCTAssertEqual(multiError.0?.error?.message.contains("ERROR"), true)
        XCTAssertEqual(multiError.1?.error?.message.contains("OTHER ERROR"), true)
    }

    func testSimpleStrings() throws {
        XCTAssertNil(try runTest("+OK"))
        XCTAssertNil(try runTest("+OK\r"))
        XCTAssertEqual(try runTest("+\r\n")?.string, "")
        XCTAssertEqual(try runTest("+OK\r\n")?.string, "OK")

        XCTAssertEqual(try runTest("+©ºmpl³x\r\n")?.string, "©ºmpl³x")

        let multiSimpleString: (RESPValue?, RESPValue?) = try runTest("+OK\r\n+OTHER STRINGS\r\n")
        XCTAssertEqual(multiSimpleString.0?.string, "OK")
        XCTAssertEqual(multiSimpleString.1?.string, "OTHER STRINGS")
    }

    func testIntegers() throws {
        XCTAssertNil(try runTest(":100"))
        XCTAssertNil(try runTest(":100\r"))
        XCTAssertNil(try runTest(":\r"))
        XCTAssertEqual(try runTest(":0\r\n")?.int, 0)
        XCTAssertEqual(try runTest(":01\r\n")?.int, 1)
        XCTAssertEqual(try runTest(":1000\r\n")?.int, 1000)
        XCTAssertEqual(try runTest(":\(Int.min)\r\n")?.int, Int.min)

        let multiInteger: (RESPValue?, RESPValue?) = try runTest(":\(Int.max)\r\n:99\r\n")
        XCTAssertEqual(multiInteger.0?.int, Int.max)
        XCTAssertEqual(multiInteger.1?.int, 99)
    }

    func testBulkStrings() throws {
        XCTAssertNil(try runTest("$0"))
        XCTAssertNil(try runTest("$0\r"))
        XCTAssertNil(try runTest("$0\r\n\r"))
        XCTAssertNil(try runTest("$-1\r"))
        XCTAssertEqual(try runTest("$-1\r\n")?.isNull, true)
        XCTAssertEqual(try runTest("$0\r\n\r\n")?.string, "")
        XCTAssertNil(try runTest("$1\r\na\r"))
        XCTAssertEqual(try runTest("$1\r\na\r\n")?.string, "a")
        XCTAssertNil(try runTest("$3\r\nfoo\r"))
        XCTAssertEqual(try runTest("$3\r\nfoo\r\n")?.string, "foo")
        XCTAssertNil(try runTest("$3\r\nn³\r"))
        XCTAssertEqual(try runTest("$3\r\nn³\r\n")?.string, "n³")

        let str = "κόσμε"
        let strBytes = str.bytes
        let strInput = "$\(strBytes.count)\r\n\(str)\r\n"
        XCTAssertEqual(try runTest(strInput)?.string, str)
        XCTAssertEqual(try runTest(strInput)?.bytes, strBytes)

        let multiBulkString: (RESPValue?, RESPValue?) = try runTest("$-1\r\n$3\r\nn³\r\n")
        XCTAssertEqual(multiBulkString.0?.isNull, true)
        XCTAssertEqual(multiBulkString.1?.string, "n³")

        let rawBytes: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x0A, 0xff]
        let rawByteInput = "$\(rawBytes.count)\r\n".bytes + rawBytes + "\r\n".bytes
        XCTAssertEqual(try runTest(rawByteInput)?.bytes, rawBytes)
    }

    func testArrays() throws {
        func runArrayTest(_ input: String) throws -> [RESPValue]? {
            return try runTest(input)?.array
        }

        XCTAssertNil(try runArrayTest("*0\r"))
        XCTAssertNil(try runArrayTest("*1\r\n+OK\r"))
        XCTAssertEqual(try runArrayTest("*0\r\n")?.count, 0)
        XCTAssertTrue(arraysAreEqual(
            try runArrayTest("*1\r\n$3\r\nfoo\r\n"),
            expected: [.init(bulk: "foo")]
        ))
        XCTAssertTrue(arraysAreEqual(
            try runArrayTest("*3\r\n+foo\r\n$3\r\nbar\r\n:3\r\n"),
            expected: [.simpleString("foo".byteBuffer), .bulkString("bar".byteBuffer), .integer(3)]
        ))
        XCTAssertTrue(arraysAreEqual(
            try runArrayTest("*1\r\n*2\r\n+OK\r\n:1\r\n"),
            expected: [.array([ .simpleString("OK".byteBuffer), .integer(1) ])]
        ))
    }

    private func runTest(_ input: String) throws -> RESPValue? {
        return try runTest(input.bytes)
    }

    private func runTest(_ input: [UInt8]) throws -> RESPValue? {
        return try runTest(input).0
    }

    private func runTest(_ input: String) throws -> (RESPValue?, RESPValue?) {
        return try runTest(input.bytes)
    }

    private func runTest(_ input: [UInt8]) throws -> (RESPValue?, RESPValue?) {
        let embeddedChannel = EmbeddedChannel()
        defer { _ = try? embeddedChannel.finish() }
        let handler = ByteToMessageHandler(decoder)
        try embeddedChannel.pipeline.addHandler(handler).wait()
        var buffer = allocator.buffer(capacity: 256)
        buffer.writeBytes(input)
        try embeddedChannel.writeInbound(buffer)
        return try (embeddedChannel.readInbound(), embeddedChannel.readInbound())
    }

    private func arraysAreEqual(
        _ lhs: [RESPValue]?,
        expected right: [RESPValue]
    ) -> Bool {
        guard
            let left = lhs,
            left.count == right.count
        else { return false }

        var arraysMatch = true

        left.enumerated().forEach {
            let (offset, decodedElement) = $0

            switch (decodedElement, right[offset]) {
            case (let .bulkString(decoded), let .bulkString(expected)): arraysMatch = decoded == expected
            case (let .simpleString(decoded), let .simpleString(expected)): arraysMatch = decoded == expected
            case (let .integer(decoded), let .integer(expected)): arraysMatch = decoded == expected
            case (let .error(decoded), let .error(expected)): arraysMatch = decoded == expected
            case (.null, .null): break
            case (let .array(decoded), let .array(expected)): arraysMatch = arraysAreEqual(decoded, expected: expected)
            default:
                XCTFail("Array mismatch!")
                arraysMatch = false
            }
        }

        return arraysMatch
    }
}

// MARK: All Types

extension RedisByteDecoderTests {
    private struct AllData {
        static let expectedString = "string"
        static let expectedError = "ERROR"
        static let expectedBulkString = "aa"
        static let expectedInteger = -1000

        static var messages = [
            "+\(expectedString)\r\n",
            ":\(expectedInteger)\r\n",
            "-\(expectedError)\r\n",
            "$2\r\n\(expectedBulkString)\r\n",
            "$-1\r\n",
            "$0\r\n\r\n",
            "*3\r\n+\(expectedString)\r\n$2\r\n\(expectedBulkString)\r\n:\(expectedInteger)\r\n",
            "*1\r\n*1\r\n:\(expectedInteger)\r\n",
            "*0\r\n",
            "*-1\r\n"
        ]
    }

    func testAll() throws {
        let embeddedChannel = EmbeddedChannel()
        defer { _ = try? embeddedChannel.finish() }
        let handler = ByteToMessageHandler(decoder)
        try embeddedChannel.pipeline.addHandler(handler).wait()

        var buffer = allocator.buffer(capacity: 256)
        for message in AllData.messages {
            buffer.writeString(message)
        }

        try embeddedChannel.writeInbound(buffer)

        var results = [RESPValue?]()
        for _ in 0..<AllData.messages.count {
            results.append(try embeddedChannel.readInbound())
        }

        XCTAssertEqual(results[0]?.string, AllData.expectedString)
        XCTAssertEqual(results[1]?.int, AllData.expectedInteger)
        XCTAssertEqual(results[2]?.error?.message.contains(AllData.expectedError), true)

        XCTAssertEqual(results[3]?.string, AllData.expectedBulkString)
        XCTAssertEqual(results[3]?.bytes, AllData.expectedBulkString.bytes)

        XCTAssertEqual(results[4]?.isNull, true)

        XCTAssertEqual(results[5]?.bytes?.count, 0)
        XCTAssertEqual(results[5]?.string, "")

        XCTAssertEqual(results[6]?.array?.count, 3)
        XCTAssertTrue(arraysAreEqual(
            results[6]?.array,
            expected: [
                .simpleString(AllData.expectedString.byteBuffer),
                .bulkString(AllData.expectedBulkString.byteBuffer),
                .integer(AllData.expectedInteger)
            ]
        ))

        XCTAssertEqual(results[7]?.array?.count, 1)
        XCTAssertTrue(arraysAreEqual(
            results[7]?.array,
            expected: [.array([.integer(AllData.expectedInteger)])]
        ))

        XCTAssertEqual(results[8]?.array?.count, 0)
        XCTAssertEqual(results[9]?.isNull, true)
    }
}

// MARK: Decoding State

extension RedisByteDecoderTests {
    func test_partial_needsMoreData() throws {
        XCTAssertEqual(try decodeTest("+OK\r"), .needMoreData)
        XCTAssertEqual(try decodeTest("$2\r\n"), .needMoreData)
        XCTAssertEqual(try decodeTest("*2\r\n:1\r\n"), .needMoreData)
        XCTAssertEqual(try decodeTest("*2\r\n*1\r\n"), .needMoreData)
        XCTAssertEqual(try decodeTest("-ERR test\r"), .needMoreData)
        XCTAssertEqual(try decodeTest(":2"), .needMoreData)
    }

    func test_badMessage_throws() {
        XCTAssertThrowsError(try decodeTest("&3\r\n").0)
    }

    private static let completeMessages = [
        "+OK\r\n",
        "$2\r\naa\r\n",
        "*2\r\n:1\r\n:2\r\n",
        "*2\r\n*1\r\n:1\r\n:2\r\n",
        "-ERR test\r\n",
        ":2\r\n"
    ]

    func test_complete_continues() throws {
        for message in RedisByteDecoderTests.completeMessages {
            XCTAssertEqual(try decodeTest(message), .continue)
        }
    }

    func test_complete_movesReaderIndex() throws {
        for message in RedisByteDecoderTests.completeMessages {
            XCTAssertEqual(try decodeTest(message).1, message.bytes.count)
        }
    }

    private func decodeTest(_ input: String) throws -> DecodingState {
        var buffer = allocator.buffer(capacity: 256)
        return try decodeTest(input, buffer: &buffer)
    }

    private func decodeTest(_ input: String) throws -> (DecodingState, Int) {
        var buffer = allocator.buffer(capacity: 256)
        return (try decodeTest(input, buffer: &buffer), buffer.readerIndex)
    }

    private func decodeTest(_ input: String, buffer: inout ByteBuffer) throws -> DecodingState {
        let embeddedChannel = EmbeddedChannel()
        defer { _ = try? embeddedChannel.finish() }
        let handler = ByteToMessageHandler(decoder)
        try embeddedChannel.pipeline.addHandler(handler).wait()
        let context = try embeddedChannel.pipeline.context(handler: handler).wait()

        buffer.writeString(input)

        return try decoder.decode(context: context, buffer: &buffer)
    }
}

// MARK: ByteToMessageDecoderVerifier

extension RedisByteDecoderTests {
    func test_validatesBasicAssumptions() throws {
        let inputExpectedOutputPairs: [(String, [RedisByteDecoder.InboundOut])] = [
            (":1000\r\n:1000\r\n", [.integer(1000), .integer(1000)]),
            (":0\r\n", [.integer(0)]),
            ("*3\r\n+foo\r\n$3\r\nbar\r\n:3\r\n",
             [.array([.simpleString("foo".byteBuffer), .bulkString("bar".byteBuffer), .integer(3)])]),
            ("+👩🏼‍✈️\r\n++\r\n", [.simpleString("👩🏼‍✈️".byteBuffer), .simpleString("+".byteBuffer)]),
            ("*2\r\n:1\r\n:2\r\n", [.array([.integer(1), .integer(2)])]),
            ("*2\r\n*1\r\n:1\r\n:2\r\n", [.array([.array([.integer(1)]), .integer(2)])]),
            ("-ERR test\r\n", [.error(.init(reason: "ERR test"))]),
            ("$2\r\n\r\n\r\n$1\r\n\r\r\n", [.bulkString("\r\n".byteBuffer), .bulkString("\r".byteBuffer)]),
            ("$-1\r\n", [.null]),
            (":00000\r\n:\(Int.max)\r\n:\(Int.min)\r\n", [.integer(0), .integer(Int.max), .integer(Int.min)]),
        ]
        XCTAssertNoThrow(try ByteToMessageDecoderVerifier.verifyDecoder(
            stringInputOutputPairs: inputExpectedOutputPairs,
            decoderFactory: RedisByteDecoder.init
        ))
    }
    
    func test_validatesBasicAssumptions_withNonStringRepresentables() throws {
        var buffer = self.allocator.buffer(capacity: 128)
        var incompleteUTF8CodeUnitsAsSimpleAndBulkString: (ByteBuffer, [RESPValue]) {
            buffer.clear()
            var expectedBuffer1 = buffer
            var expectedBuffer2 = buffer
            buffer.writeString("+")
            // UTF8 2 byte sequence with only 1 byte present
            expectedBuffer1.writeInteger(0b110_10101, as: UInt8.self)
            buffer.writeBytes(expectedBuffer1.readableBytesView)
            buffer.writeString("\r\n")
            buffer.writeString("$2\r\n")
            // UTF8 3 byte sequence with only 2 bytes present
            expectedBuffer2.writeInteger(0b1110_1010, as: UInt8.self)
            expectedBuffer2.writeInteger(0b10_101010, as: UInt8.self)
            buffer.writeBytes(expectedBuffer2.readableBytesView)
            buffer.writeString("\r\n")
            return (buffer, [.simpleString(expectedBuffer1), .bulkString(expectedBuffer2)])
        }
        var boms: (ByteBuffer, [RESPValue]) {
            buffer.clear()
            var expectedBuffer1 = buffer
            var expectedBuffer2 = buffer
            buffer.writeString("+")
            // UTF16 LE BOM
            expectedBuffer1.writeInteger(0xff, as: UInt8.self)
            expectedBuffer1.writeInteger(0xfe, as: UInt8.self)
            buffer.writeBytes(expectedBuffer1.readableBytesView)
            buffer.writeString("\r\n")
            buffer.writeString("$4\r\n")
            // UTF32 BE BOM
            expectedBuffer2.writeInteger(0x00, as: UInt8.self)
            expectedBuffer2.writeInteger(0x00, as: UInt8.self)
            expectedBuffer2.writeInteger(0xFE, as: UInt8.self)
            expectedBuffer2.writeInteger(0xFF, as: UInt8.self)
            buffer.writeBytes(expectedBuffer2.readableBytesView)
            buffer.writeString("\r\n")
            return (buffer, [.simpleString(expectedBuffer1), .bulkString(expectedBuffer2)])
        }
        let inputExpectedOutputPairs: [(ByteBuffer, [RedisByteDecoder.InboundOut])] = [
            incompleteUTF8CodeUnitsAsSimpleAndBulkString,
            boms,
        ]
        XCTAssertNoThrow(try ByteToMessageDecoderVerifier.verifyDecoder(
            inputOutputPairs: inputExpectedOutputPairs,
            decoderFactory: RedisByteDecoder.init
        ))
    }
}
