import Foundation
import LanternCore
import Darwin

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("Usage: lantern-serve FOLDER [INTERFACE-IP] [PORT]\n", stderr); exit(2) }
guard let interface = LANInterface.available().first(where: { args.count < 3 || $0.address == args[2] }) else { fputs("No matching LAN interface\n", stderr); exit(2) }
let port = args.count > 3 ? UInt16(args[3]) ?? 8200 : 8200
do {
    let library = try Library(root: URL(fileURLWithPath: args[1]))
    let server = DLNAServer(uuid: "d0d7792b-a5bc-4d8c-9196-2a8f32518200")
    server.onLog = { print($0); fflush(stdout) }
    server.onState = { running, detail in print("\(running ? "READY" : "STOPPED") \(detail)"); fflush(stdout) }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown = { server.stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) } }
    interrupt.setEventHandler(handler: shutdown); terminate.setEventHandler(handler: shutdown)
    interrupt.resume(); terminate.resume()
    server.start(library: library, interface: interface, port: port)
    RunLoop.main.run()
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
