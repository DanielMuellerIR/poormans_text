#if os(Linux)
// Linux Foundation besitzt keine Objective-C-Autorelease-Pools.
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
