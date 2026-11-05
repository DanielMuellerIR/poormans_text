// swift-tools-version: 6.2
import PackageDescription
let package=Package(name:"OCRBridgeProbe",targets:[.target(name:"CoreProbe"),.testTarget(name:"CoreProbeTests",dependencies:["CoreProbe"])])
