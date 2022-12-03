//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2020-2022 RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import RediStack
import XCTest
import NIOCore
import NIOEmbedded

internal enum MockConnectionPoolError: Error {
    case unexpectedMessage
}

// TODO #64 -- Mock Redis Server

/// This is not really a Redis server: it's just something that lets us stub out the connection management in order to let
/// us test the connection pool.
internal final class EmbeddedMockRedisServer {
    var channels: ArraySlice<EmbeddedChannel> = []
    var loop: EmbeddedEventLoop = EmbeddedEventLoop()

    // Run the fake redis server as long as there is work to do.
    func runWhileActive() throws {
        var anyReads = true

        while anyReads {
            self.loop.run()

            anyReads = false
            for channel in self.channels {
                anyReads = try self.pumpChannel(channel) || anyReads
            }
        }
    }

    func pumpChannel(_ channel: EmbeddedChannel) throws -> Bool {
        var didRead = false

        while let nextRead = try channel.readOutbound(as: RedisCommandHandler.OutboundCommandPayload.self) {
            didRead = true
            try self.processChannelRead(nextRead, channel)
        }

        return didRead
    }

    func processChannelRead(_ data: RedisCommandHandler.OutboundCommandPayload, _ channel: Channel) throws {
        switch data.message {
        case .array([RESPValue(from: "QUIT")]):
            // We always allow this.
            let response = RESPValue.simpleString("OK".byteBuffer)
            data.responsePromise.succeed(response)

        default:
            XCTFail("Unexpected message: \(data.message)")
            data.responsePromise.fail(MockConnectionPoolError.unexpectedMessage)
        }
    }

    func createConnectedChannel() -> Channel {
        let channel = EmbeddedChannel(loop: self.loop)
        channel.closeFuture.whenComplete { _ in
            self.channels.removeAll(where: { $0 === channel })
        }

        // Activate it
        channel.connect(to: try! SocketAddress(unixDomainSocketPath: "/foo"), promise: nil)
        self.channels.append(channel)
        return channel
    }

    func shutdown() throws {
        try self.runWhileActive()
        try self.loop.close()
    }
}
