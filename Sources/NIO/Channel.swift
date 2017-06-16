//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Sockets

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum IOData {
    case byteBuffer(ByteBuffer)
    case other(Any)

    public func tryAsByteBuffer() -> ByteBuffer? {
        if case .byteBuffer(let bb) = self {
            return bb
        } else {
            return nil
        }
    }

    public func forceAsByteBuffer() -> ByteBuffer {
        return tryAsByteBuffer()!
    }

    public func tryAsOther<T>(class: T.Type = T.self) -> T? {
        if case .other(let any) = self {
            return any as? T
        } else {
            return nil
        }
    }

    public func forceAsOther<T>(class: T.Type = T.self) -> T {
        return tryAsOther(class: `class`)!
    }
}

final class PendingWrite {
    var next: PendingWrite?
    var buffer: ByteBuffer
    let promise: Promise<Void>

    init(buffer: ByteBuffer, promise: Promise<Void>) {
        self.buffer = buffer
        self.promise = promise
    }
}

func doPendingWriteVectorOperation(pending: PendingWrite?,
                                   count: Int,
                                   iovecs: UnsafeMutableBufferPointer<IOVector>,
                                   storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>,
                                   _ fn: (UnsafeBufferPointer<IOVector>) -> Int) -> Int {
    var next = pending
    for i in 0..<count {
        if let p = next {
            p.buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                _ = storageRef.retain()
                storageRefs[i] = storageRef
                iovecs[i] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: ptr.count)
            }
            next = p.next
        } else {
            break
        }
    }
    let result = fn(UnsafeBufferPointer(start: iovecs.baseAddress!, count: count))
    for i in 0..<count {
        storageRefs[i].release()
    }
    return result
}

func makeNonThrowing<I>(errorBuffer: inout Error?, input: I, _ fn: (I) throws -> Int?) -> Int {
    do {
        if let bytes = try fn(input) {
            return bytes
        } else {
            return 0
        }
    } catch let e {
        errorBuffer = e
        return -1
    }
}

final fileprivate class PendingWrites {
    
    private var head: PendingWrite?
    private var tail: PendingWrite?
    // Marks the last PendingWrite that should be written by consume(...)
    private var flushCheckpoint: PendingWrite?
    private var iovecs: UnsafeMutableBufferPointer<IOVector>
    private var storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>
    
    fileprivate var waterMark: WriteBufferWaterMark = WriteBufferWaterMark(32 * 1024..<64 * 1024)
    private var writable = true
    
    fileprivate var writeSpinCount: UInt = 16
    private(set) var outstanding: (chunks: Int, bytes: Int) = (0, 0)
    
    private(set) var closed = false
    
    var isEmpty: Bool {
        return tail == nil
    }
    
    func add(buffer: ByteBuffer, promise: Promise<Void>) -> Bool {
        let pending: PendingWrite = PendingWrite(buffer: buffer, promise: promise)
        if let last = tail {
            assert(head != nil)
            last.next = pending
            tail = pending
        } else {
            assert(tail == nil)
            head = pending
            tail = pending
        }
        outstanding = (chunks: outstanding.chunks + 1,
                       bytes: outstanding.bytes + buffer.readableBytes)
        if writable && outstanding.bytes > Int(waterMark.upperBound) {
            writable = false
            // Returns false to signal the Channel became non-writable and we need to notify the user
            return false
        }
        return true
    }
    
    private var hasMultiple: Bool {
        return head?.next != nil
    }
    
    func markFlushCheckpoint() {
        flushCheckpoint = tail
    }
    
    /*
     Function that takes two closures and based on if there are more then one ByteBuffer pending calls either one or the other.
    */
    func consume(oneBody: (UnsafePointer<UInt8>, Int) throws -> Int?, multipleBody: (UnsafeBufferPointer<IOVector>) throws -> Int?) throws -> (consumedAll:Bool?, writable: Bool) {
        let wasWritable = writable
        let result: Bool?
        if hasMultiple {
            // Holds multiple pending writes, use consumeMultiple which will allow us to us writev (a.k.a gathering writes)
            result = try consumeMultiple(body: multipleBody)
        } else {
            result = try consumeOne(body: oneBody)
        }
        
        if !wasWritable {
            // Was not writable before so signal back to the caller the possible state change
            return (result, writable)
        }
        return (result, false)
    }
    
    private func updateNodes(pending: PendingWrite) {
        head = pending.next
        if head == nil {
            tail = nil
            flushCheckpoint = nil
        }
    }
    
    private func isFlushCheckpoint(_ pending: PendingWrite) -> Bool {
        return pending === flushCheckpoint
    }
    
    private func checkFlushCheckpoint(pending: PendingWrite) -> Bool {
        if isFlushCheckpoint(pending) {
            flushCheckpoint = nil
            return true
        }
        return false
    }
    
    private func isFlushPending() -> Bool {
        return flushCheckpoint != nil
    }
    
    private func consumeOne(body: (UnsafePointer<UInt8>, Int) throws -> Int?) rethrows -> Bool? {
        if let pending = head, isFlushPending() {
            for _ in 0..<writeSpinCount + 1 {
                guard !closed else {
                    return true
                }
                if let written = try pending.buffer.withReadPointer(body: body) {
                    outstanding = (outstanding.chunks, outstanding.bytes - written)
                    
                    if !writable && outstanding.bytes < Int(waterMark.lowerBound) {
                        writable = true
                    }
                    
                    if pending.buffer.readableBytes == written {
                        
                        // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                        updateNodes(pending: pending)
                        
                        outstanding = (outstanding.chunks-1, outstanding.bytes)
                        
                        let allFlushed = checkFlushCheckpoint(pending: pending)
                        
                        // buffer was completely written
                        pending.promise.succeed(result: ())
                        
                        if isEmpty || allFlushed {
                            // return nil to signal to the caller that there are no more buffers to consume
                            return nil
                        }
                        // Wrote the full buffer
                        return true
                    } else {
                        // Update readerIndex of the buffer
                        pending.buffer.skipBytes(num: written)
                    }
                } else {
                    return false
                }
            }
            // could not write the complete buffer
            return false
        }
        
        // empty or flushed everything that is marked to be flushable
        return nil
    }
    
    private func consumeMultiple(body: (UnsafeBufferPointer<IOVector>) throws -> Int?) throws -> Bool? {
        if var pending = head, isFlushPending() {
            writeLoop: for _ in 0..<writeSpinCount + 1 {
                guard !closed else {
                    return true
                }
                var expected = 0
                var error: Error? = nil
                let written = doPendingWriteVectorOperation(pending: pending,
                                                            count: outstanding.chunks,
                                                            iovecs: self.iovecs,
                                                            storageRefs: self.storageRefs) { pointer in
                    expected += pointer.count
                    return makeNonThrowing(errorBuffer: &error, input: pointer, body)
                }
                
                if written < 0 {
                    throw error!
                } else if written == 0 {
                    return nil
                } else if written > 0 {
                    outstanding = (outstanding.chunks, outstanding.bytes - written)
                    
                    if !writable && outstanding.bytes < Int(waterMark.lowerBound) {
                        writable = true
                    }
                    
                    var allFlushed = false
                    var w = written
                    while let p = head {
                        assert(!allFlushed)
                        
                        if w >= p.buffer.readableBytes {
                            w -= p.buffer.readableBytes
                            
                            outstanding = (outstanding.chunks-1, outstanding.bytes)

                            // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                            updateNodes(pending: p)
                            
                            allFlushed = checkFlushCheckpoint(pending: p)
                            
                            // buffer was completely written
                            p.promise.succeed(result: ())
                        } else {
                            // Only partly written, so update the readerIndex.
                            p.buffer.skipBytes(num: w)
                            
                            // update pending so we not need to process the old PendingWrites that we already processed and completed
                            pending = p

                            // may try again depending on the writeSpinCount
                            continue writeLoop
                        }
                    }
                    
                    if isEmpty || allFlushed {
                        // return nil to signal to the caller that there are no more buffers to consume
                        return nil
                    }

                    // check if we were able to write everything or not
                    assert(expected == written)
                    return true
                }
            }
            // could not write the complete buffer
            return false
        }
        
        // empty or flushed everything that is marked to be flushable
        return nil
    }
    
    
    private func killAll(node: PendingWrite?, deconstructor: (PendingWrite) -> ()) {
        var link = node
        while link != nil {
            let curr = link!
            link = curr.next
            curr.next = nil
            deconstructor(curr)
        }
    }
    
    func failAll(error: Error) {
        closed = true
        
        /*
         Workaround for https://bugs.swift.org/browse/SR-5145 which is that this linked list can cause a
         stack overflow when released as the `deinit`s will get called with recursion.
        */
        
        killAll(node: head, deconstructor: { pending in
            outstanding = (outstanding.chunks-1, outstanding.bytes - pending.buffer.readableBytes)
            
            pending.promise.fail(error: error)
        })
        
        // Remove references.
        head = nil
        tail = nil
        flushCheckpoint = nil
        
        assert(outstanding == (0, 0))
    }
    
    init(iovecs: UnsafeMutableBufferPointer<IOVector>, storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>) {
        self.iovecs = iovecs
        self.storageRefs = storageRefs
    }
}

/*
 All operations on SocketChannel are thread-safe
 */
final class SocketChannel : BaseSocketChannel<Socket> {
    
    init(eventLoop: SelectableEventLoop) throws {
        let socket = try Socket()
        do {
            try socket.setNonBlocking()
        } catch let err {
            let _ = try? socket.close()
            throw err
        }
        
        try super.init(socket: socket, eventLoop: eventLoop)
    }
    
    fileprivate override init(socket: Socket, eventLoop: SelectableEventLoop) throws {
        try socket.setNonBlocking()
        try super.init(socket: socket, eventLoop: eventLoop)
    }
    
    override fileprivate func readFromSocket() throws {
        // Just allocate one time for the while read loop. This is fine as ByteBuffer is a struct and uses COW.
        var buffer = try recvAllocator.buffer(allocator: allocator)
        for _ in 1...maxMessagesPerRead {
            guard !closed else {
                return
            }
            if let bytesRead = try buffer.withMutableWritePointer { try self.socket.read(pointer: $0, size: $1) } {
                if bytesRead > 0 {
                    recvAllocator.record(actualReadBytes: bytesRead)

                    pipeline.fireChannelRead0(data: .byteBuffer(buffer))
                    
                    // Reset reader and writerIndex and so allow to have the buffer filled again
                    buffer.clear()
                } else {
                    // end-of-file
                    throw ChannelError.eof
                }
            } else {
                return
            }
        }
    }
    
    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> Bool? {
        let result = try pendingWrites.consume(oneBody: {
            guard $1 > 0 else {
                // No need to call write if the buffer is empty.
                return 0
            }
            // normal write
            return try self.socket.write(pointer: $0, size: $1)
        }, multipleBody: {
            switch $0.count {
            case 0:
                // No need to call write if the buffer is empty.
                return 0
            case 1:
                let p = $0[0]
                return try self.socket.write(pointer: p.iov_base.assumingMemoryBound(to: UInt8.self), size: p.iov_len)
            default:
                // Gathering write
                return try self.socket.writev(iovecs: $0)
            }
        })
        if result.writable {
            // writable again
            pipeline.fireChannelWritabilityChanged0(writable: true)
        }
        return result.consumedAll
    }
    
    override fileprivate func connectSocket(remote: SocketAddress) throws -> Bool {
        return try self.socket.connect(remote: remote)
    }
    
    override fileprivate func finishConnectSocket() throws {
        try self.socket.finishConnect()
    }
}

/*
 All operations on ServerSocketChannel are thread-safe
 */
final class ServerSocketChannel : BaseSocketChannel<ServerSocket> {
    
    private var backlog: Int32 = 128
    private let group: EventLoopGroup
    
    init(eventLoop: SelectableEventLoop, group: EventLoopGroup) throws {
        let serverSocket = try ServerSocket()
        do {
            try serverSocket.setNonBlocking()
        } catch let err {
            let _ = try? serverSocket.close()
            throw err
        }
        self.group = group
        try super.init(socket: serverSocket, eventLoop: eventLoop)
    }

    override fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)
        if option is BacklogOption {
            backlog = value as! Int32
        } else {
            try super.setOption0(option: option, value: value)
        }
    }
    
    override fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        if option is BacklogOption {
            return backlog as! T.OptionType
        }
        return try super.getOption0(option: option)
    }

    override public func bind0(local: SocketAddress, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)
        do {
            try socket.bind(local: local)
            try self.socket.listen(backlog: backlog)
            promise.succeed(result: ())
            pipeline.fireChannelActive0()
        } catch let err {
            promise.fail(error: err)
        }
    }
    
    override fileprivate func connectSocket(remote: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }
    
    override fileprivate func finishConnectSocket() throws {
        throw ChannelError.operationUnsupported
    }
    
    override fileprivate func readFromSocket() throws {
        for _ in 1...maxMessagesPerRead {
            guard !closed else {
                return
            }
            if let accepted =  try self.socket.accept() {
                do {
                    pipeline.fireChannelRead0(data: .other(try SocketChannel(socket: accepted, eventLoop: group.next() as! SelectableEventLoop)))
                } catch let err {
                    let _ = try? accepted.close()
                    throw err
                }
            } else {
                return
            }
        }
    }
    
    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> Bool? {
        pendingWrites.failAll(error: ChannelError.operationUnsupported)
        return true
    }
    
    override public func channelRead0(data: IOData) {
        assert(eventLoop.inEventLoop)

        let ch = data.forceAsOther() as Channel
        let f = ch.register()
        f.whenFailure(callback: { err in
            _ = ch.close()
        })
        f.whenSuccess { () -> Void in
            ch.pipeline.fireChannelActive0()
        }
    }
}


/*
 All methods must be called from the EventLoop thread
 */
public protocol ChannelCore : class{
    func register0(promise: Promise<Void>)
    func bind0(local: SocketAddress, promise: Promise<Void>)
    func connect0(remote: SocketAddress, promise: Promise<Void>)
    func write0(data: IOData, promise: Promise<Void>)
    func flush0()
    func readIfNeeded0()
    func startReading0()
    func stopReading0()
    func close0(promise: Promise<Void>, error: Error)
    func channelRead0(data: IOData)
    var closed: Bool { get }
    var eventLoop: EventLoop { get }
}

/*
 All methods exposed by Channel are thread-safe
 */
public protocol Channel : class, ChannelOutboundInvoker {
    var allocator: ByteBufferAllocator { get }

    var closeFuture: Future<Void> { get }

    var pipeline: ChannelPipeline { get }
    var localAddress: SocketAddress? { get }
    var remoteAddress: SocketAddress? { get }

    func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws
    func getOption<T: ChannelOption>(option: T) throws -> T.OptionType

    @discardableResult func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void>
    @discardableResult func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void>
    func read()
    @discardableResult func write(data: IOData, promise: Promise<Void>) -> Future<Void>
    func flush()
    @discardableResult func writeAndFlush(data: IOData, promise: Promise<Void>) -> Future<Void>
    @discardableResult func close(promise: Promise<Void>) -> Future<Void>

    var _unsafe: ChannelCore { get }
}

protocol SelectableChannel : Channel {
    var selectable: Selectable { get }
    var interestedEvent: InterestedEvent { get }

    func writable()
    func readable()
}

extension Channel {
    public var open: Bool {
        return !closeFuture.fulfilled
    }
    
    var eventLoop: EventLoop {
        return _unsafe.eventLoop
    }

    @discardableResult public func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        return pipeline.bind(local: local, promise: promise)
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    // By default, just pass through to pipeline

    @discardableResult public func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        return pipeline.connect(remote: remote, promise: promise)
    }

    @discardableResult public func write(data: IOData, promise: Promise<Void>) -> Future<Void> {
        return pipeline.write(data: data, promise: promise)
    }

    public func flush() {
        pipeline.flush()
    }

    public func read() {
        pipeline.read()
    }

    @discardableResult public func writeAndFlush(data: IOData, promise: Promise<Void>) -> Future<Void> {
        return pipeline.writeAndFlush(data: data, promise: promise)
    }

    @discardableResult public func close(promise: Promise<Void>) -> Future<Void> {
        return pipeline.close(promise: promise)
    }


    @discardableResult public func register(promise: Promise<Void>) -> Future<Void> {
        return pipeline.register(promise: promise)
    }
}

class BaseSocketChannel<T : BaseSocket> : SelectableChannel, ChannelCore {

    public final var selectable: Selectable { return socket }

    public final var _unsafe: ChannelCore { return self }

    // Visible to access from EventLoop directly
    let socket: T
    public var interestedEvent: InterestedEvent = .none

    public final var closed: Bool {
        return pendingWrites.closed
    }

    private let pendingWrites: PendingWrites
    private var readPending = false
    private var neverRegistered = true
    private var pendingConnect: Promise<Void>?
    private let closePromise: Promise<Void>
    
    public final var closeFuture: Future<Void> {
        return closePromise.futureResult
    }
    
    private let selectableEventLoop: SelectableEventLoop
    
    public final var eventLoop: EventLoop {
        return selectableEventLoop
    }
    
    public final var allocator: ByteBufferAllocator {
        if eventLoop.inEventLoop {
            return bufferAllocator
        } else {
            return try! eventLoop.submit{ self.bufferAllocator }.wait()
        }
    }

    private var bufferAllocator: ByteBufferAllocator = ByteBufferAllocator()
    fileprivate var recvAllocator: RecvByteBufferAllocator = AdaptiveRecvByteBufferAllocator()
    fileprivate var autoRead: Bool = true
    fileprivate var maxMessagesPerRead: UInt = 1

    // We don't use lazy var here as this is more expensive then doing this :/
    public final var pipeline: ChannelPipeline {
        return _pipeline
    }
    
    private var _pipeline: ChannelPipeline!
    
    public final func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws {
        if eventLoop.inEventLoop {
            try setOption0(option: option, value: value)
        } else {
            let _ = try eventLoop.submit{
                try self.setOption0(option: option, value: value)
            }.wait()
        }
    }
    
    fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        if option is SocketOption {
            let (level, name) = option.value as! (Int, Int32)
            try socket.setOption(level: Int32(level), name: name, value: value)
        } else if option is AllocatorOption {
            bufferAllocator = value as! ByteBufferAllocator
        } else if option is RecvAllocatorOption {
            recvAllocator = value as! RecvByteBufferAllocator
        } else if option is AutoReadOption {
            let auto = value as! Bool
            autoRead = auto
            if auto {
                startReading0()
            } else {
                stopReading0()
            }
        } else if option is MaxMessagesPerReadOption {
            maxMessagesPerRead = value as! UInt
        } else if option is WriteSpinOption {
            pendingWrites.writeSpinCount = value as! UInt
        } else if option is WriteBufferWaterMark {
            pendingWrites.waterMark = value as! WriteBufferWaterMark
        } else {
            fatalError("option \(option) not supported")
        }
    }

    public final func getOption<T: ChannelOption>(option: T) throws -> T.OptionType {
        if eventLoop.inEventLoop {
            return try getOption0(option: option)
        } else {
            return try eventLoop.submit{ try self.getOption0(option: option) }.wait()
        }
    }
    
    fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        
        if option is SocketOption {
            let (level, name) = option.value as! (Int32, Int32)
            return try socket.getOption(level: level, name: name)
        }
        if option is AllocatorOption {
            return bufferAllocator as! T.OptionType
        }
        if option is RecvAllocatorOption {
            return recvAllocator as! T.OptionType
        }
        if option is AutoReadOption {
            return autoRead as! T.OptionType
        }
        if option is MaxMessagesPerReadOption {
            return maxMessagesPerRead as! T.OptionType
        }
        if option is WriteSpinOption {
            return pendingWrites.writeSpinCount as! T.OptionType
        }
        if option is WriteBufferWaterMarkOption {
            return pendingWrites.waterMark as! T.OptionType
        }
        fatalError("option \(option) not supported")
    }
    
    public final var localAddress: SocketAddress? {
        get {
            return socket.localAddress
        }
    }

    public final var remoteAddress: SocketAddress? {
        get {
            return socket.remoteAddress
        }
    }

    public final func readIfNeeded0() {
        if autoRead {
            pipeline.read0()
        }
    }

    @discardableResult public final func register(promise: Promise<Void>) -> Future<Void> {
        return pipeline.register(promise: promise)
    }
    
    @discardableResult public final func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        return pipeline.bind(local: local, promise: promise)
    }
    
    @discardableResult public final func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        return pipeline.connect(remote: remote, promise: promise)
    }
    
    @discardableResult public final func write(data: IOData, promise: Promise<Void>) -> Future<Void> {
        return pipeline.write(data: data, promise: promise)
    }
    
    public final func flush() {
        pipeline.flush()
    }
    
    public final func read() {
        pipeline.read()
    }
    
    @discardableResult public final func writeAndFlush(data: IOData, promise: Promise<Void>) -> Future<Void> {
        return pipeline.writeAndFlush(data: data, promise: promise)
    }
    
    @discardableResult public final func close(promise: Promise<Void>) -> Future<Void> {
        return pipeline.close(promise: promise)
    }
    
    // Methods invoked from the HeadHandler of the ChannelPipeline
    public func bind0(local: SocketAddress, promise: Promise<Void> ) {
        assert(eventLoop.inEventLoop)

        do {
            try socket.bind(local: local)
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
    }

    public func write0(data: IOData, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            // Channel was already closed, fail the promise and not even queue it.
            promise.fail(error: ChannelError.closed)
            return
        }
        if let buffer = data.tryAsByteBuffer() {
            if !pendingWrites.add(buffer: buffer, promise: promise) {
                pipeline.fireChannelWritabilityChanged0(writable: false)
            }
        } else {
            // Only support ByteBuffer for now. 
            promise.fail(error: ChannelError.messageUnsupported)
        }
    }

    private func registerForWritable() {
        switch interestedEvent {
        case .read:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .write)
        default:
            break
        }
    }

    public final func flush0() {
        assert(eventLoop.inEventLoop)

        // Even if writable() will be called later by the EVentLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actual written once writable() is called.
        pendingWrites.markFlushCheckpoint()

        guard !isWritePending() else {
            return
        }
        
        if !flushNow() {
            guard !closed else {
                return
            }

            registerForWritable()
        }
    }
    
    public final func startReading0() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }
        readPending = true
        
        registerForReadable()
    }

    public final func stopReading0() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }
        unregisterForReadable()
    }
    
    private func registerForReadable() {
        switch interestedEvent {
        case .write:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .read)
        default:
            break
        }
    }
    
    private func unregisterForReadable() {
        switch interestedEvent {
        case .read:
            safeReregister(interested: .none)
        case .all:
            safeReregister(interested: .write)
        default:
            break
        }
    }
    
    public final func close0(promise: Promise<Void>, error: Error) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            // Already closed
            promise.succeed(result: ())
            return
        }
        
        // Fail all pending writes and so ensure all pending promises are notified
        pendingWrites.failAll(error: error)
        
        safeDeregister()

        do {
            try socket.close()
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
        if !neverRegistered {
            pipeline.fireChannelUnregistered0()
        }
        pipeline.fireChannelInactive0()
        
        
        // Fail all pending writes and so ensure all pending promises are notified
        pendingWrites.failAll(error: error)
        
        if let connectPromise = pendingConnect {
            pendingConnect = nil
            connectPromise.fail(error: error)
        }
        closePromise.succeed(result: ())
    }
    

    public final func register0(promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        // Was not registered yet so do it now.
        if safeRegister(interested: .read) {
            neverRegistered = false
            promise.succeed(result: ())
            pipeline.fireChannelRegistered0()
        } else {
            promise.succeed(result: ())
        }
    }
    

    // Methods invoked from the EventLoop itself
    public final func writable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)

        if finishConnect() || flushNow() {
            // Everything was written or connect was complete
            finishWritable()
            return
        }
    }
    
    private func finishConnect() -> Bool {
        if let connectPromise = pendingConnect {
            pendingConnect = nil
            do {
                try finishConnectSocket()
                connectPromise.succeed(result: ())
            } catch let error {
                connectPromise.fail(error: error)
            }
            return true
        }
        return false
    }
    
    private func finishWritable() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }
        
        if readPending {
            // Start reading again
            safeReregister(interested: .read)
        } else {
            // No read pending so just set the interested event to .none
            safeReregister(interested: .none)
        }
    }
    
    public final func readable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)
        
        readPending = false
        defer {
            if !closed, !readPending {
                unregisterForReadable()
            }
        }
        
        do {
            try readFromSocket()
        } catch let err {
            if let channelErr = err as? ChannelError {
                // EOF is not really an error that should be forwarded to the user
                if channelErr != ChannelError.eof {
                    pipeline.fireErrorCaught0(error: err)
                }
            } else {
                pipeline.fireErrorCaught0(error: err)
            }
            
            // Call before triggering the close of the Channel.
            pipeline.fireChannelReadComplete0()
            close0(promise: eventLoop.newPromise(type: Void.self), error: err)
            
            return
            
        }
        pipeline.fireChannelReadComplete0()
    }
    
    fileprivate func connectSocket(remote: SocketAddress) throws -> Bool {
        fatalError("this must be overridden by sub class")
    }
    
    fileprivate func finishConnectSocket() throws {
        fatalError("this must be overridden by sub class")
    }
    
    public final func connect0(remote: SocketAddress, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        guard pendingConnect == nil else {
            promise.fail(error: ChannelError.connectPending)
            return
        }
        do {
            if try !connectSocket(remote: remote) {
                registerForWritable()
            }
        } catch let error {
            promise.fail(error: error)
        }
    }
    
    fileprivate func readFromSocket() throws {
        fatalError("this must be overridden by sub class")
    }

    
    fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> Bool? {
        fatalError("this must be overridden by sub class")
    }
    
    public func channelRead0(data: IOData) {
        // Do nothing by default
    }

    private func isWritePending() -> Bool {
        return interestedEvent == .write || interestedEvent == .all
    }
    
    // Methods only used from within this class
    private func safeDeregister() {
        interestedEvent = .none
        do {
            try selectableEventLoop.deregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(promise: eventLoop.newPromise(type: Void.self), error: err)
        }
    }
    
    private func safeReregister(interested: InterestedEvent) {
        guard !closed else {
            interestedEvent = .none
            return
        }
        guard interested != interestedEvent else {
            // we not need to update and so cause a syscall if we already are registered with the correct event
            return
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.reregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(promise: eventLoop.newPromise(type: Void.self), error: err)
        }
    }
    
    private func safeRegister(interested: InterestedEvent) -> Bool {
        guard !closed else {
            interestedEvent = .none
            return false
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.register(channel: self)
            return true
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(promise: eventLoop.newPromise(type: Void.self), error: err)
            return false
        }
    }

    private func flushNow() -> Bool {
        while !closed {
            do {
                if let written = try writeToSocket(pendingWrites: pendingWrites) {
                    if !written {
                        // Could not write the next buffer(s) completely
                        return false
                    }
                    // Consume the next buffer(s).
                } else {
                    
                    // we handled all pending writes
                    return true
                }
                
            } catch let err {
                close0(promise: eventLoop.newPromise(type: Void.self), error: err)
                
                // we handled all writes
                return true
            }
        }
        return true
    }
    
    fileprivate init(socket: T, eventLoop: SelectableEventLoop) throws {
        self.socket = socket
        self.selectableEventLoop = eventLoop
        self.closePromise = eventLoop.newPromise(type: Void.self)
        self.pendingWrites = PendingWrites(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        self._pipeline = ChannelPipeline(channel: self)
    }
    
    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(pendingWrites.isEmpty)
    }
}

public enum ChannelError: Error {
    case connectPending
    case messageUnsupported
    case operationUnsupported
    case closed
    case eof
}
