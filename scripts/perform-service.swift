// Invokes the "Copy to Gist" service the way a right-click does, for smoke tests:
//   swift scripts/perform-service.swift text "some text"
//   swift scripts/perform-service.swift image photo.png
//   swift scripts/perform-service.swift files a.txt folder/
import AppKit
let args = CommandLine.arguments
let pb = NSPasteboard.withUniqueName()
pb.clearContents()
if args[1] == "text" { pb.setString(args[2], forType: .string) }
else if args[1] == "image" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    pb.setData(data, forType: args[2].hasSuffix(".tiff") ? .tiff : .png)
}
else if args[1] == "rtfd" {
    // Reproduces a Notes photo selection: flat RTFD with the image as an
    // embedded attachment, U+FFFC as the plain text, and no image types.
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    let fw = FileWrapper(regularFileWithContents: data)
    fw.preferredFilename = (args[2] as NSString).lastPathComponent
    let s = NSAttributedString(attachment: NSTextAttachment(fileWrapper: fw))
    let flat = try! s.data(from: NSRange(location: 0, length: s.length),
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    pb.setData(flat, forType: .rtfd)
    pb.setString("\u{FFFC}", forType: .string)
}
else { pb.writeObjects(args.dropFirst(2).map { URL(fileURLWithPath: $0) as NSURL }) }
print(NSPerformService("Copy to Gist", pb))
