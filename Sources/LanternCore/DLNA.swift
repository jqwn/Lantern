import Foundation

public final class DLNAServer {
    private let queue = DispatchQueue(label: "Lantern.server")
    private var http: HTTPServer?
    private var discovery: Discovery?
    private var library: Library?
    private var base = ""
    private var subscriptions: [String: (path: String, callback: URL, expires: Date)] = [:]
    private var notifications: [String: URLSessionDataTask] = [:]
    private lazy var eventSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration, delegate: LocalEventDelegate { [weak self] sid in
            self?.queue.async { [weak self] in self?.notifications.removeValue(forKey: sid) }
        }, delegateQueue: nil)
    }()
    private let uuid: String
    public var onLog: ((String) -> Void)?
    public var onState: ((Bool, String) -> Void)?

    public init(uuid: String) { self.uuid = uuid }

    public func start(library: Library, interface: LANInterface, port: UInt16 = 8200) {
        queue.async { [self] in
            self.stopOnQueue()
            self.library = library
            let http = HTTPServer(queue: self.queue)
            self.http = http
            http.handler = { [weak self] in self?.respond($0) ?? HTTPResponse(503) }
            http.state = { [weak self, weak http] result in
                guard let self, let http, self.http === http else { return }
                switch result {
                case .success(let port):
                    self.base = "http://\(interface.address):\(port)"
                    let discovery = Discovery(queue: self.queue, interface: interface, uuid: self.uuid, location: self.base + "/description.xml", log: { [weak self] in self?.onLog?($0) })
                    do {
                        try discovery.start()
                        self.discovery = discovery
                        self.onState?(true, self.base)
                        self.onLog?("Sharing \(library.videos.count) videos on \(interface.label)")
                    } catch { self.stopOnQueue(); self.onState?(false, "Discovery failed: \(error.localizedDescription)") }
                case .failure(let error): self.stopOnQueue(); self.onState?(false, error.localizedDescription)
                }
            }
            do { try http.start(address: interface.address, port: port) }
            catch { self.stopOnQueue(); self.onState?(false, error.localizedDescription) }
        }
    }

    public func stop() { queue.async { self.stopOnQueue(); self.onState?(false, "Sharing stopped") } }
    public func shutdown() { queue.sync { stopOnQueue() } }
    private func stopOnQueue() {
        discovery?.stop(); discovery = nil; http?.stop(); http = nil
        subscriptions.removeAll()
        notifications.values.forEach { $0.cancel() }; notifications.removeAll()
    }

    private func respond(_ request: HTTPRequest) -> HTTPResponse {
        guard let library else { return HTTPResponse(503) }
        if request.method == "SUBSCRIBE" || request.method == "UNSUBSCRIBE" { return subscribe(request) }
        if request.method == "POST" {
            let service = request.path == "/control/content" ? "ContentDirectory" : request.path == "/control/connection" ? "ConnectionManager" : ""
            guard !service.isEmpty else { return HTTPResponse(404) }
            onLog?("TV requested \(request.headers["soapaction"] ?? "SOAP")")
            return SOAP.respond(request, service: service, library: library, base: base)
        }
        guard request.method == "GET" || request.method == "HEAD" else { return HTTPResponse(405) }
        switch request.path {
        case "/description.xml": return HTTPResponse(text: Self.description(uuid: uuid))
        case "/content.xml": return HTTPResponse(text: SOAP.scpd(service: "ContentDirectory"))
        case "/connection.xml": return HTTPResponse(text: SOAP.scpd(service: "ConnectionManager"))
        case "/": return HTTPResponse(text: "Lantern is sharing \(library.videos.count) videos. Open Connected Devices / Sources on your TV and select Lantern.", type: "text/plain; charset=utf-8")
        default: break
        }
        let parts = request.path.split(separator: "/")
        guard parts.count == 2, let id = parts.last?.split(separator: ".").first, let item = library.items[String(id)], !item.isFolder else { return HTTPResponse(404) }
        if parts[0] == "subtitles", let subtitle = item.subtitle {
            guard subtitle.resolvingSymlinksInPath() == subtitle.standardizedFileURL else { return HTTPResponse(404) }
            onLog?("Serving subtitles: \(item.title)")
            return HTTPResponse.stream(url: subtitle, type: "application/x-subrip; charset=utf-8", request: request)
        }
        guard parts[0] == "media" else { return HTTPResponse(404) }
        // Revalidate at access time as a shared path could have been replaced with a symlink.
        let resolved = item.url.resolvingSymlinksInPath()
        guard resolved == item.url.standardizedFileURL, resolved.path.hasPrefix(library.root.path + "/") else { return HTTPResponse(404) }
        var headers = ["transferMode.dlna.org": "Streaming", "contentFeatures.dlna.org": "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"]
        if item.subtitle != nil { headers["CaptionInfo.sec"] = "\(base)/subtitles/\(item.id).srt" }
        onLog?("\(request.method) \(item.title)\(request.headers["range"].map { " · \($0)" } ?? "")")
        return HTTPResponse.stream(url: item.url, type: item.mime, request: request, headers: headers)
    }

    private func subscribe(_ request: HTTPRequest) -> HTTPResponse {
        guard ["/events/content", "/events/connection"].contains(request.path) else { return HTTPResponse(404) }
        subscriptions = subscriptions.filter { $0.value.expires > Date() }
        if let sid = request.headers["sid"] {
            guard let existing = subscriptions[sid], existing.path == request.path, existing.callback.host == request.peerAddress,
                  request.headers["callback"] == nil, request.headers["nt"] == nil else { return HTTPResponse(412) }
            if request.method == "UNSUBSCRIBE" {
                subscriptions.removeValue(forKey: sid)
                notifications.removeValue(forKey: sid)?.cancel()
                return HTTPResponse()
            }
            subscriptions[sid]?.expires = Date().addingTimeInterval(300)
            return HTTPResponse(headers: ["SID": sid, "TIMEOUT": "Second-300"])
        }
        guard request.method == "SUBSCRIBE", request.headers["nt"] == "upnp:event", subscriptions.count < 32,
              let callback = request.headers["callback"], callback.hasPrefix("<"), callback.hasSuffix(">"),
              let url = URL(string: String(callback.dropFirst().dropLast())), url.scheme == "http",
              let peer = request.peerAddress, url.host == peer, url.user == nil, url.password == nil, url.fragment == nil else { return HTTPResponse(412) }
        // Only notify the requesting device, never an arbitrary URL supplied by a LAN client.
        let sid = "uuid:\(UUID().uuidString.lowercased())"
        subscriptions[sid] = (request.path, url, Date().addingTimeInterval(300))
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let subscription = self.subscriptions[sid], let library = self.library else { return }
            let properties = subscription.path == "/events/content" ? "<e:property><SystemUpdateID>\(library.revision)</SystemUpdateID></e:property>" : "<e:property><SourceProtocolInfo>\(SOAP.protocols)</SourceProtocolInfo></e:property><e:property><SinkProtocolInfo></SinkProtocolInfo></e:property><e:property><CurrentConnectionIDs>0</CurrentConnectionIDs></e:property>"
            var notification = URLRequest(url: subscription.callback, timeoutInterval: 5)
            notification.httpMethod = "NOTIFY"
            notification.httpBody = Data("<?xml version=\"1.0\"?><e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">\(properties)</e:propertyset>".utf8)
            notification.allHTTPHeaderFields = ["Content-Type": "text/xml; charset=utf-8", "NT": "upnp:event", "NTS": "upnp:propchange", "SID": sid, "SEQ": "0"]
            let task = self.eventSession.dataTask(with: notification)
            task.taskDescription = sid
            self.notifications[sid] = task
            task.resume()
        }
        return HTTPResponse(headers: ["SID": sid, "TIMEOUT": "Second-300"])
    }

    public static func description(uuid: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion><device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><friendlyName>Lantern</friendlyName><manufacturer>Lantern</manufacturer><modelDescription>Local video library</modelDescription><modelName>Lantern</modelName><modelNumber>0.1</modelNumber><UDN>uuid:\(xml(uuid))</UDN><dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId><SCPDURL>/content.xml</SCPDURL><controlURL>/control/content</controlURL><eventSubURL>/events/content</eventSubURL></service><service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><SCPDURL>/connection.xml</SCPDURL><controlURL>/control/connection</controlURL><eventSubURL>/events/connection</eventSubURL></service></serviceList></device></root>
        """
    }
}

private final class LocalEventDelegate: NSObject, URLSessionDataDelegate {
    let completed: (String) -> Void
    init(completed: @escaping (String) -> Void) { self.completed = completed }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) { completionHandler(.cancel) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let sid = task.taskDescription { completed(sid) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum SOAP {
    public static func respond(_ request: HTTPRequest, service: String, library: Library, base: String) -> HTTPResponse {
        let parser = SOAPParser()
        let xmlParser = XMLParser(data: request.body)
        xmlParser.shouldProcessNamespaces = true
        xmlParser.shouldResolveExternalEntities = false
        xmlParser.delegate = parser
        guard !String(decoding: request.body, as: UTF8.self).contains("<!DOCTYPE"), xmlParser.parse(), let action = parser.action,
              parser.service == "urn:schemas-upnp-org:service:\(service):1",
              request.headers["soapaction"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == "urn:schemas-upnp-org:service:\(service):1#\(action)" else { return fault(402, "Invalid Args") }
        let args = parser.values
        var body = ""
        if service == "ContentDirectory" {
            switch action {
            case "Browse":
                guard let id = args["ObjectID"], let item = library.items[id] else { return fault(701, "No Such Object") }
                guard let start = Int(args["StartingIndex"] ?? ""), let count = Int(args["RequestedCount"] ?? ""), start >= 0, count >= 0 else { return fault(402, "Invalid Args") }
                let sort = args["SortCriteria"] ?? ""
                guard ["", "+dc:title", "-dc:title"].contains(sort) else { return fault(709, "Unsupported Sort Criteria") }
                let entries: [MediaItem]
                if args["BrowseFlag"] == "BrowseMetadata" { entries = [item] }
                else if args["BrowseFlag"] == "BrowseDirectChildren", item.isFolder { entries = library.children(of: id) }
                else { return fault(402, "Invalid Args") }
                let sorted = sort.isEmpty ? entries : entries.sorted { sort == "-dc:title" ? $0.title.localizedStandardCompare($1.title) == .orderedDescending : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let rest = sorted.dropFirst(min(start, sorted.count))
                let page = count == 0 ? Array(rest) : Array(rest.prefix(count))
                body = "<Result>\(xml(library.didl(page, base: base)))</Result><NumberReturned>\(page.count)</NumberReturned><TotalMatches>\(entries.count)</TotalMatches><UpdateID>\(library.revision)</UpdateID>"
            case "GetSearchCapabilities": body = "<SearchCaps></SearchCaps>"
            case "GetSortCapabilities": body = "<SortCaps>dc:title</SortCaps>"
            case "GetSystemUpdateID": body = "<Id>\(library.revision)</Id>"
            default: return fault(401, "Invalid Action")
            }
        } else {
            switch action {
            case "GetProtocolInfo": body = "<Source>\(protocols)</Source><Sink></Sink>"
            case "GetCurrentConnectionIDs": body = "<ConnectionIDs>0</ConnectionIDs>"
            case "GetCurrentConnectionInfo":
                guard args["ConnectionID"] == "0" else { return fault(706, "Invalid Connection Reference") }
                body = "<RcsID>-1</RcsID><AVTransportID>-1</AVTransportID><ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager><PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction><Status>OK</Status>"
            default: return fault(401, "Invalid Action")
            }
        }
        return HTTPResponse(text: envelope("<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">\(body)</u:\(action)Response>"))
    }

    static var protocols: String { ["video/mp4", "video/x-matroska", "video/quicktime", "video/mpeg", "video/mp2t", "video/x-msvideo"].map { "http-get:*:\($0):*" }.joined(separator: ",") }
    static func envelope(_ body: String) -> String { "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\(body)</s:Body></s:Envelope>" }
    static func fault(_ code: Int, _ text: String) -> HTTPResponse { HTTPResponse(500, text: envelope("<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(code)</errorCode><errorDescription>\(text)</errorDescription></UPnPError></detail></s:Fault>")) }

    public static func scpd(service: String) -> String {
        typealias Argument = (String, String, String)
        let actions: [(String, [Argument])]
        let variables: [(String, String)]
        if service == "ContentDirectory" {
            actions = [("Browse", [("ObjectID", "in", "A_ARG_TYPE_ObjectID"), ("BrowseFlag", "in", "A_ARG_TYPE_BrowseFlag"), ("Filter", "in", "A_ARG_TYPE_Filter"), ("StartingIndex", "in", "A_ARG_TYPE_Index"), ("RequestedCount", "in", "A_ARG_TYPE_Count"), ("SortCriteria", "in", "A_ARG_TYPE_SortCriteria"), ("Result", "out", "A_ARG_TYPE_Result"), ("NumberReturned", "out", "A_ARG_TYPE_Count"), ("TotalMatches", "out", "A_ARG_TYPE_Count"), ("UpdateID", "out", "A_ARG_TYPE_UpdateID")]), ("GetSearchCapabilities", [("SearchCaps", "out", "SearchCapabilities")]), ("GetSortCapabilities", [("SortCaps", "out", "SortCapabilities")]), ("GetSystemUpdateID", [("Id", "out", "SystemUpdateID")])]
            variables = [("A_ARG_TYPE_ObjectID", "string"), ("A_ARG_TYPE_BrowseFlag", "string"), ("A_ARG_TYPE_Filter", "string"), ("A_ARG_TYPE_Index", "ui4"), ("A_ARG_TYPE_Count", "ui4"), ("A_ARG_TYPE_SortCriteria", "string"), ("A_ARG_TYPE_Result", "string"), ("A_ARG_TYPE_UpdateID", "ui4"), ("SearchCapabilities", "string"), ("SortCapabilities", "string"), ("SystemUpdateID", "ui4")]
        } else {
            actions = [("GetProtocolInfo", [("Source", "out", "SourceProtocolInfo"), ("Sink", "out", "SinkProtocolInfo")]), ("GetCurrentConnectionIDs", [("ConnectionIDs", "out", "CurrentConnectionIDs")]), ("GetCurrentConnectionInfo", [("ConnectionID", "in", "A_ARG_TYPE_ConnectionID"), ("RcsID", "out", "A_ARG_TYPE_RcsID"), ("AVTransportID", "out", "A_ARG_TYPE_AVTransportID"), ("ProtocolInfo", "out", "A_ARG_TYPE_ProtocolInfo"), ("PeerConnectionManager", "out", "A_ARG_TYPE_ConnectionManager"), ("PeerConnectionID", "out", "A_ARG_TYPE_ConnectionID"), ("Direction", "out", "A_ARG_TYPE_Direction"), ("Status", "out", "A_ARG_TYPE_ConnectionStatus")])]
            variables = [("SourceProtocolInfo", "string"), ("SinkProtocolInfo", "string"), ("CurrentConnectionIDs", "string"), ("A_ARG_TYPE_ConnectionID", "i4"), ("A_ARG_TYPE_RcsID", "i4"), ("A_ARG_TYPE_AVTransportID", "i4"), ("A_ARG_TYPE_ProtocolInfo", "string"), ("A_ARG_TYPE_ConnectionManager", "string"), ("A_ARG_TYPE_Direction", "string"), ("A_ARG_TYPE_ConnectionStatus", "string")]
        }
        let actionXML = actions.map { name, args in "<action><name>\(name)</name><argumentList>" + args.map { "<argument><name>\($0.0)</name><direction>\($0.1)</direction><relatedStateVariable>\($0.2)</relatedStateVariable></argument>" }.joined() + "</argumentList></action>" }.joined()
        let stateXML = variables.map { name, type in
            let allowed: String
            switch name {
            case "A_ARG_TYPE_BrowseFlag": allowed = "<allowedValueList><allowedValue>BrowseMetadata</allowedValue><allowedValue>BrowseDirectChildren</allowedValue></allowedValueList>"
            case "A_ARG_TYPE_Direction": allowed = "<allowedValueList><allowedValue>Input</allowedValue><allowedValue>Output</allowedValue></allowedValueList>"
            case "A_ARG_TYPE_ConnectionStatus": allowed = "<allowedValueList><allowedValue>OK</allowedValue><allowedValue>Unknown</allowedValue><allowedValue>ContentFormatMismatch</allowedValue><allowedValue>InsufficientBandwidth</allowedValue><allowedValue>UnreliableChannel</allowedValue></allowedValueList>"
            default: allowed = ""
            }
            let evented = ["SystemUpdateID", "SourceProtocolInfo", "SinkProtocolInfo", "CurrentConnectionIDs"].contains(name)
            return "<stateVariable sendEvents=\"\(evented ? "yes" : "no")\"><name>\(name)</name><dataType>\(type)</dataType>\(allowed)</stateVariable>"
        }.joined()
        return "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>\(actionXML)</actionList><serviceStateTable>\(stateXML)</serviceStateTable></scpd>"
    }
}

private final class SOAPParser: NSObject, XMLParserDelegate {
    var action: String?
    var service: String?
    var values: [String: String] = [:]
    var stack: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(elementName)
        if stack.count == 3 && stack[0] == "Envelope" && stack[1] == "Body" { action = elementName; service = namespaceURI }
        if stack.count == 4 { values[elementName] = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if stack.count == 4, let name = stack.last { values[name, default: ""] += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { stack.removeLast() }
}
