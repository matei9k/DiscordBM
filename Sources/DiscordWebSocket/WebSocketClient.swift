import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOTransportServices
import Atomics

public final class WebSocketClient: @unchecked Sendable {

    public enum Error: LocalizedError, CustomStringConvertible {
        case invalidURLString(String)
        case invalidResponseStatus(HTTPResponseHead)
        case alreadyShutdown

        public var description: String {
            switch self {
            case let .invalidURLString(url):
                return "WebSocketClient.Error.invalidURLString(\(url))"
            case let .invalidResponseStatus(head):
                return "WebSocketClient.Error.invalidResponseStatus(\(head))"
            case .alreadyShutdown:
                return "WebSocketClient.Error.alreadyShutdown"
            }
        }

        public var errorDescription: String? {
            self.description
        }

        public var helpAnchor: String? {
            switch self {
            case let .invalidURLString(url):
                return "The URL string was invalid: \(url)"
            case let .invalidResponseStatus(head):
                return "Received invalid status code. Make sure the connection you wan to make is acceptable by the peer. HTTP head: \(head)"
            case .alreadyShutdown:
                return "Do not attempt to shutdown the web-socket client when already shut down."
            }
        }
    }

    public enum EventLoopGroupProvider {
        case shared(EventLoopGroup)
        case createNew
    }

    public struct Configuration: Sendable {
        public var tlsConfiguration: TLSConfiguration?
        public var maxFrameSize: Int
        public var decompression: Decompression.Configuration?
        
        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            maxFrameSize: Int = 1 << 14
        ) {
            self.tlsConfiguration = tlsConfiguration
            self.maxFrameSize = maxFrameSize
            self.decompression = nil
        }
        
        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            maxFrameSize: Int = 1 << 14,
            decompression: Decompression.Configuration?
        ) {
            self.tlsConfiguration = tlsConfiguration
            self.maxFrameSize = maxFrameSize
            self.decompression = decompression
        }
    }

    let eventLoopGroupProvider: EventLoopGroupProvider
    let group: EventLoopGroup
    let configuration: Configuration
    let isShutdown = ManagedAtomic(false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = .init()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.group = group
        case .createNew:
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        self.configuration = configuration
    }

    func connect(
        scheme: String,
        host: String,
        port: Int,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        onBuffer: @Sendable @escaping (ByteBuffer) -> () = { _ in },
        onClose: @Sendable @escaping (WebSocket) -> () = { _ in }
    ) async throws -> WebSocket {
        try await withCheckedThrowingContinuation { continuation in
            assert(["ws", "wss"].contains(scheme))
            let upgradePromise = self.group.next().makePromise(of: Void.self)
            let bootstrap = WebSocketClient.makeBootstrap(on: self.group)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    let httpHandler = HTTPInitialRequestHandler(
                        host: host,
                        path: path,
                        query: query,
                        headers: headers,
                        upgradePromise: upgradePromise
                    )

                    var key: [UInt8] = []
                    for _ in 0..<16 {
                        key.append(.random(in: .min ..< .max))
                    }

                    let websocketUpgrader = NIOWebSocketClientUpgrader(
                        requestKey:  Data(key).base64EncodedString(),
                        maxFrameSize: self.configuration.maxFrameSize,
                        automaticErrorHandling: true,
                        upgradePipelineHandler: { channel, req in
                            channel.eventLoop.makeFutureWithTask {
                                let webSocket = try await WebSocket.client(
                                    on: channel,
                                    decompression: self.configuration.decompression,
                                    onBuffer: onBuffer,
                                    onClose: onClose
                                )
                                continuation.resume(returning: webSocket)
                            }
                        }
                    )

                    let config: NIOHTTPClientUpgradeConfiguration = (
                        upgraders: [websocketUpgrader],
                        completionHandler: { context in
                            upgradePromise.succeed(())
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )

                    if scheme == "wss" {
                        do {
                            let context = try NIOSSLContext(
                                configuration: self.configuration.tlsConfiguration ?? .makeClientConfiguration()
                            )
                            let tlsHandler: NIOSSLClientHandler
                            do {
                                tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: host)
                            } catch let error as NIOSSLExtraError where error == .cannotUseIPAddressInSNI {
                                tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: nil)
                            }
                            return channel.pipeline.addHandler(tlsHandler).flatMap {
                                channel.pipeline.addHTTPClientHandlers(
                                    leftOverBytesStrategy: .forwardBytes,
                                    withClientUpgrade: config
                                )
                            }.flatMap {
                                channel.pipeline.addHandler(httpHandler)
                            }
                        } catch {
                            return channel.pipeline.close(mode: .all)
                        }
                    } else {
                        return channel.pipeline.addHTTPClientHandlers(
                            leftOverBytesStrategy: .forwardBytes,
                            withClientUpgrade: config
                        ).flatMap {
                            channel.pipeline.addHandler(httpHandler)
                        }
                    }
                }

            let connect = bootstrap.connect(host: host, port: port)
            connect.cascadeFailure(to: upgradePromise)
            connect.flatMap { channel in
                upgradePromise.futureResult
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }

    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            if self.isShutdown.compareExchange(
                expected: false,
                desired: true,
                ordering: .relaxed
            ).exchanged {
                try self.group.syncShutdownGracefully()
            } else {
                throw WebSocketClient.Error.alreadyShutdown
            }
        }
    }
    
    private static func makeBootstrap(on eventLoop: EventLoopGroup) -> NIOClientTCPBootstrapProtocol {
        #if canImport(Network)
        if let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
            return tsBootstrap
        }
       #endif

       if let nioBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
           return nioBootstrap
       }

       fatalError("No matching bootstrap found")
    }

    deinit {
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            assert(self.isShutdown.load(ordering: .relaxed), "WebSocketClient not shutdown before deinit.")
        }
    }
}