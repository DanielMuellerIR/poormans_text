// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "P02Probe", products: [.executable(name:"pmt-probe",targets:["Probe"])], dependencies: [.package(url:"https://github.com/apple/swift-crypto.git",exact:"4.2.0")], targets:[.systemLibrary(name:"zlib",pkgConfig:"zlib"),.target(name:"PoorMansTextCore",dependencies:["zlib",.product(name:"Crypto",package:"swift-crypto")]),.executableTarget(name:"Probe",dependencies:["PoorMansTextCore"])],swiftLanguageModes:[.v6])
