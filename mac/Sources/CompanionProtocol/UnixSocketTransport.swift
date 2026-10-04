// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Dispatch
import Foundation

/// Newline-delimited JSON over a Unix domain socket.
///
/// The transport knows about lines, not about messages: `DaemonClient` decodes. All socket
/// work runs on one private serial queue; handlers are called on the delivery queue the
/// caller passes in. Messages are small control frames, so the write path blocks on that
/// private queue instead of buffering.
public final class UnixSocketTransport: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case connected
        case closed
        case failed(TransportError)
    }

    private let queue = DispatchQueue(label: "companion.protocol.transport")
    private let deliveryQueue: DispatchQueue
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()
    private var state: State = .idle

    private var lineHandler: (@Sendable (Data) -> Void)?
    private var stateHandler: (@Sendable (State) -> Void)?

    public init(deliveryQueue: DispatchQueue = .main) {
        self.deliveryQueue = deliveryQueue
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    /// Called for every complete line, without its newline.
    public func onLine(_ handler: @escaping @Sendable (Data) -> Void) {
        queue.async { self.lineHandler = handler }
    }

    public func onStateChange(_ handler: @escaping @Sendable (State) -> Void) {
        queue.async { self.stateHandler = handler }
    }

    public func connect(toSocketAt path: String) {
        queue.async { self.connectOnQueue(path) }
    }

    /// Writes one line. The newline is added here, so no caller can forget it and merge two
    /// messages into one.
    public func send(line: Data) {
        queue.async {
            guard self.descriptor >= 0, case .connected = self.state else { return }
            var payload = line
            payload.append(0x0A)
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        self.descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        self.failOnQueue(.connectFailed(errno: errno))
                        return
                    }
                }
            }
        }
    }

    public func close() {
        queue.async { self.closeOnQueue(newState: .closed) }
    }

    // MARK: - Private, all on `queue`

    private func connectOnQueue(_ path: String) {
        closeOnQueue(newState: .idle, notify: false)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else {
            failOnQueue(.socketPathTooLong(max: capacity - 1))
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            failOnQueue(.connectFailed(errno: errno))
            return
        }
        // A closed daemon socket must surface as an error, never as a process-wide SIGPIPE.
        var on: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fileDescriptor)
            failOnQueue(.connectFailed(errno: code))
            return
        }

        descriptor = fileDescriptor
        framer = LineFramer()
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fileDescriptor) }
        readSource = source
        source.resume()
        setState(.connected)
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = chunk.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        if count == 0 {
            closeOnQueue(newState: .closed)
            return
        }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            failOnQueue(.connectFailed(errno: errno))
            return
        }
        let lines: [Data]
        do {
            lines = try framer.push(Data(chunk[0..<count]))
        } catch let error as TransportError {
            failOnQueue(error)
            return
        } catch {
            failOnQueue(.notConnected)
            return
        }
        guard let handler = lineHandler else { return }
        for line in lines {
            deliveryQueue.async { handler(line) }
        }
    }

    private func closeOnQueue(newState: State, notify: Bool = true) {
        readSource?.cancel()
        readSource = nil
        descriptor = -1
        framer = LineFramer()
        if notify {
            setState(newState)
        } else {
            state = newState
        }
    }

    private func failOnQueue(_ error: TransportError) {
        readSource?.cancel()
        readSource = nil
        descriptor = -1
        setState(.failed(error))
    }

    private func setState(_ newState: State) {
        state = newState
        guard let handler = stateHandler else { return }
        deliveryQueue.async { handler(newState) }
    }
}
