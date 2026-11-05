import CoreFoundation
func encoding(_ name: String) -> CFStringEncoding? {
    guard let identifier = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.UTF8.rawValue) else { return nil }
    defer { CFRelease(identifier) }
    return CFStringConvertIANACharSetNameToEncoding(identifier)
}
