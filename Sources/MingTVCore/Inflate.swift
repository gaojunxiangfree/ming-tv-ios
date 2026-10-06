import Foundation

#if canImport(Compression)
import Compression
#endif

public extension Data {
    /// 以 raw DEFLATE (无 zlib/gzip 头) 解压
    func inflateRawDeflate() -> Data? {
        #if canImport(Compression)
        guard !isEmpty else { return Data() }

        var out = Data()
        let bufferSize = 64 * 1024
        // 目标缓冲区手动分配, 保证生命周期覆盖整个解压过程
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        let code: Int32 = self.withUnsafeBytes { srcRaw -> Int32 in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { streamPtr.deallocate() }
            streamPtr.initialize(to: compression_stream(dst_ptr: dst, dst_size: 0,
                                                        src_ptr: src, src_size: 0,
                                                        state: nil))
            defer { streamPtr.deinitialize(count: 1) }

            guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                    == COMPRESSION_STATUS_OK else { return -1 }
            defer { compression_stream_destroy(streamPtr) }

            streamPtr.pointee.src_ptr = src
            streamPtr.pointee.src_size = count

            var status = COMPRESSION_STATUS_OK
            repeat {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = bufferSize
                status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_ERROR { return -1 }
                let produced = bufferSize - streamPtr.pointee.dst_size
                if produced > 0 { out.append(dst, count: produced) }
            } while status == COMPRESSION_STATUS_OK
            return 0
        }

        return code == 0 ? out : nil
        #else
        return nil
        #endif
    }
}
