import Foundation
@testable import PoorMansTextCore

let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let names=["01030000000132","01030000000132-render","01030000000135","structured"]
var positive=[[String:Any]]();var negative=[[String:Any]]()
func require(_ ok: Bool,_ message: String) throws { if !ok { throw DoclingDocumentProjection.Failure(reason:message) } }
func byteInventory(_ strings: [String]) -> [String:Int] {
    var counts=[String:Int]()
    for string in strings { for word in string.split(whereSeparator: \.isWhitespace) {
        counts[Data(word.utf8).base64EncodedString(),default:0] += 1
    } }
    return counts
}
for name in names {
    let data=try Data(contentsOf:directory.appendingPathComponent(name+".json"))
    let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent(name+"-result.json"))) as! [String:Any]
    try require(ConversionFileFingerprint.digest(data)==receipt["jsonSHA256"] as? String,"stored JSON digest mismatch")
    do {
        let parsed=try DoclingDocumentProjection.parse(data)
        let rendered=try StructuredOCRRendering.render(parsed.recognition)
        let raw=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let rawTexts=raw["texts"] as! [[String:Any]]
        let rawTables=raw["tables"] as! [[String:Any]]
        let rawCells=rawTables.flatMap { ($0["data"] as! [String:Any])["table_cells"] as! [[String:Any]] }
        let authority=StructuredOCRRendering.inventory(rawTexts.map { $0["orig"] as! String }+rawCells.map { $0["text"] as! String })
        try require(parsed.rawCellCount==rawCells.count,"raw cell count differs")
        let output=StructuredOCRRendering.inventory(rendered.blocks.map(\.text))
        try require(authority==output,"renderer inventory differs from JSON authority")
        let rawAuthority=rawTexts.map { $0["orig"] as! String }+rawCells.map { $0["text"] as! String }
        let bytesMatch=byteInventory(rawAuthority)==byteInventory(rendered.blocks.map(\.text))
        try require(bytesMatch,"UTF8 token bytes differ from JSON authority")
        let header=name=="structured" ? "MERGED HEADER":"Fish species on IUCN Red List"
        let appearances=rendered.markdown.components(separatedBy:header).count-1
        if parsed.rawCellCount>0 { try require(appearances==1,"span header duplicated") }
        positive.append(["case":name,"passed":true,"JSON_SHA256":ConversionFileFingerprint.digest(data),"sourceSHA256FromReceipt":receipt["sourceSHA256"]!,"rawCellCount":parsed.rawCellCount,"rawTextNodeCount":rawTexts.count,"projectedTextFragmentCount":parsed.items.filter{$0.label != "table_cell"}.count,"footerCount":parsed.items.filter{$0.label=="page_footer"}.count,"captionCount":parsed.items.filter{$0.label=="caption"}.count,"rendererBlocks":rendered.blocks.count,"spansFlattened":rendered.flattenedSpans,"headerOccurrences":appearances,"JSONAuthorityEqualsRendererTextInventory":authority==output,"JSONAuthorityUTF8TokenBytesMatch":bytesMatch,"projectedTables":try JSONSerialization.jsonObject(with:JSONEncoder().encode(parsed.recognition.documents.flatMap(\.tables))),"inventory":authority,"items":try JSONSerialization.jsonObject(with:JSONEncoder().encode(parsed.items)),"picturesNotRendered":parsed.pictureRefs,"markdown":rendered.markdown])
    } catch { positive.append(["case":name,"passed":false,"error":String(describing:error)]) }
}
let baseline=try Data(contentsOf:directory.appendingPathComponent("01030000000132.json"))
let object=try JSONSerialization.jsonObject(with:baseline) as! [String:Any]
@MainActor func mutated(_ body:(inout [String:Any])->Void) throws -> Data { var copy=object;body(&copy);return try JSONSerialization.data(withJSONObject:copy,options:[.sortedKeys]) }
var tests=[(String,Data)]()
tests.append(("missing-reference",try mutated { root in var body=root["body"] as! [String:Any];var children=body["children"] as! [[String:Any]];children[0]=["$ref":"#/tables/99"];body["children"]=children;root["body"]=body }))
tests.append(("missing-node",try mutated { root in var texts=root["texts"] as! [[String:Any]];texts.removeLast();root["texts"]=texts }))
tests.append(("structural-cycle",try mutated { root in var body=root["body"] as! [String:Any];var children=body["children"] as! [[String:Any]];children.append(["$ref":"#/body"]);body["children"]=children;root["body"]=body }))
tests.append(("missing-caption-ref",try mutated { root in var pictures=root["pictures"] as! [[String:Any]];pictures[0]["captions"]=[["$ref":"#/texts/99"]];root["pictures"]=pictures }))
@MainActor func tableMutation(_ body:(inout [String:Any])->Void) throws -> Data { try mutated { root in var tables=root["tables"] as! [[String:Any]];var data=tables[0]["data"] as! [String:Any];body(&data);tables[0]["data"]=data;root["tables"]=tables } }
tests.append(("overlapping-span",try tableMutation { data in var cells=data["table_cells"] as! [[String:Any]];cells[1]["start_row_offset_idx"]=0;cells[1]["end_row_offset_idx"]=1;data["table_cells"]=cells }))
tests.append(("span-mismatch",try tableMutation { data in var cells=data["table_cells"] as! [[String:Any]];cells[0]["col_span"]=1;data["table_cells"]=cells }))
tests.append(("missing-cell",try tableMutation { data in var cells=data["table_cells"] as! [[String:Any]];cells.removeLast();data["table_cells"]=cells }))
tests.append(("out-of-page-cell",try tableMutation { data in var cells=data["table_cells"] as! [[String:Any]];var box=cells[0]["bbox"] as! [String:Any];box["r"]=900;cells[0]["bbox"]=box;data["table_cells"]=cells }))
tests.append(("unknown-origin",try tableMutation { data in var cells=data["table_cells"] as! [[String:Any]];var box=cells[0]["bbox"] as! [String:Any];box["coord_origin"]="UNSPECIFIED";cells[0]["bbox"]=box;data["table_cells"]=cells }))
tests.append(("table-budget",try tableMutation { $0["num_cols"]=257 }))
tests.append(("JSON-budget",Data(repeating:32,count:8*1024*1024+1)))
let fragmentedObject=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("structured.json"))) as! [String:Any]
@MainActor func fragmentMutation(_ mutation:(inout [String:Any])->Void) throws -> Data {
    var copy=fragmentedObject;var texts=copy["texts"] as! [[String:Any]];mutation(&texts[2]);copy["texts"]=texts
    return try JSONSerialization.data(withJSONObject:copy,options:[.sortedKeys])
}
tests.append(("fragment-overlap",try fragmentMutation { node in var prov=node["prov"] as! [[String:Any]];prov[1]["charspan"]=[18,41];node["prov"]=prov }))
tests.append(("fragment-out-of-bounds",try fragmentMutation { node in var prov=node["prov"] as! [[String:Any]];prov[2]["charspan"]=[42,64];node["prov"]=prov }))
tests.append(("fragment-missing-provenance",try fragmentMutation { $0["prov"]=[] }))
tests.append(("fragment-uncovered-text",try fragmentMutation { node in var prov=node["prov"] as! [[String:Any]];prov.remove(at:1);node["prov"]=prov }))
tests.append(("fragment-ambiguous-basis",try fragmentMutation { $0["text"]="different alternative text" }))
tests.append(("fragment-reordered",try fragmentMutation { node in var prov=node["prov"] as! [[String:Any]];prov.swapAt(0,1);node["prov"]=prov }))
let unicode=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("unicode-control.json"))) as! [String:Any]
let controlText=unicode["text"] as! String
let controlFragments=try DoclingDocumentProjection.scalarFragments(original:controlText,alternate:controlText,spans:unicode["spans"] as! [[Int]])
let pythonFragments=unicode["fragments"] as! [String]
try require(controlFragments.map { Array($0.utf8) }==pythonFragments.map { Array($0.utf8) },"Python/Swift scalar slice mismatch")
try require(controlText.unicodeScalars.count==unicode["pythonCodepointCount"] as! Int,"codepoint count mismatch")
do {
    _=try DoclingDocumentProjection.scalarFragments(original:controlText,alternate:controlText.precomposedStringWithCanonicalMapping,spans:unicode["spans"] as! [[Int]])
    negative.append(["case":"unicode-canonical-equivalent-ambiguous-basis","rejected":false])
} catch { negative.append(["case":"unicode-canonical-equivalent-ambiguous-basis","rejected":true,"error":String(describing:error)]) }
let unicodeEvidence:[String:Any]=["text":controlText,"SwiftUnicodeScalars":controlText.unicodeScalars.count,"SwiftGraphemeCount":controlText.count,"UTF16Count":controlText.utf16.count,"UTF8Bytes":controlText.utf8.count,"fragments":controlFragments,"matchesPythonUTF8Bytes":true]
for (name,data) in tests {
    do { _=try DoclingDocumentProjection.parse(data);negative.append(["case":name,"rejected":false]) }
    catch { negative.append(["case":name,"rejected":true,"error":String(describing:error)]) }
}
let report:[String:Any]=["positive":positive,"negative":negative,"unicode":unicodeEvidence,"allPassed":positive.allSatisfy{$0["passed"] as? Bool==true} && negative.allSatisfy{$0["rejected"] as? Bool==true},"scope":"JSON projection only; table paragraphs are derived from authoritative cells, not independent OCR; no GT recovery or product qualification"]
let output=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(output);FileHandle.standardOutput.write(Data("\n".utf8))

if report["allPassed"] as? Bool != true { exit(1) }
