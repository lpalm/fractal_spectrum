import Foundation

/// FNV-1a hash in hexadecimal: stable across launches, unlike `hashValue`.
public func stableHash(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 {
        h ^= UInt64(b)
        h &*= 0x100000001b3
    }
    return String(h, radix: 16)
}

/// Changes whenever the kernels or palettes do: a version for caches of rendered images.
public let renderSignature = stableHash(fractalShaderSource + Palette.all.map { "\($0.id)\($0.stops)" }.joined())
