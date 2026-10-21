import AVFoundation
import CoreMedia

/// Core Media wrappers for compressed frames, for writing them to a file as they are.
enum SampleBuffers {
    static func videoFormat(codec: StreamCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        let joined = parameterSets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
        let sizes = parameterSets.map(\.count)
        var format: CMFormatDescription?
        let status: OSStatus = joined.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            if codec == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sizes.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sizes.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    static func audioFormat(_ header: ADTSHeader) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(header.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(header.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(header.channels == 0 ? 2 : header.channels),
            mBitsPerChannel: 0, mReserved: 0)
        let cookie = header.esdsCookie
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: bytes.baseAddress, extensions: nil,
                formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// One video frame in MP4 form (each NAL unit behind a 4-byte length).
    static func videoSample(
        _ unit: VideoAccessUnit, duration: Int64, format: CMVideoFormatDescription, offset: Int64
    ) -> CMSampleBuffer? {
        var data = Data()
        for nal in unit.nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(nal)
        }
        guard let block = blockBuffer(data) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: 90000),
            presentationTimeStamp: CMTime(value: unit.pts - offset, timescale: 90000),
            decodeTimeStamp: CMTime(value: unit.dts - offset, timescale: 90000))
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample
        else { return nil }
        if !unit.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// AAC frames starting at `start` (in samples), as packets of one buffer.
    static func audioSample(_ frames: [Data], start: Int64, sampleRate: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        var data = Data()
        var packets: [AudioStreamPacketDescription] = []
        for frame in frames {
            packets.append(AudioStreamPacketDescription(
                mStartOffset: Int64(data.count), mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count)))
            data.append(frame)
        }
        guard !frames.isEmpty, let block = blockBuffer(data) else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames.count,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: packets, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    private static func blockBuffer(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard !data.isEmpty,
              CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block
        else { return nil }
        let status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        return status == noErr ? block : nil
    }
}
