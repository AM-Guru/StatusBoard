import Foundation

// sbctl — push data to a running Status Board bridge from the terminal.
//
//   sbctl push --key cpu --number 42.5 --unit % [--history 120]
//   sbctl push --key note --text "Deploy finished"
//   sbctl pipe --key cpu            # reads one number per stdin line
//   any command accepts --host localhost --port 7311 --token SECRET

struct Options {
    var host = "localhost"
    var port = 7311
    var token: String?
    var key: String?
    var number: Double?
    var text: String?
    var unit: String?
    var history: Int?
    var interval: Double = 0
}

func parseOptions(_ arguments: ArraySlice<String>) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--host": options.host = iterator.next() ?? options.host
        case "--port": options.port = Int(iterator.next() ?? "") ?? options.port
        case "--token": options.token = iterator.next()
        case "--key": options.key = iterator.next()
        case "--number": options.number = Double(iterator.next() ?? "")
        case "--text": options.text = iterator.next()
        case "--unit": options.unit = iterator.next()
        case "--history": options.history = Int(iterator.next() ?? "")
        case "--interval": options.interval = Double(iterator.next() ?? "") ?? 0
        default:
            FileHandle.standardError.write(Data("unknown option: \(argument)\n".utf8))
            exit(2)
        }
    }
    return options
}

@discardableResult
func push(_ options: Options, number: Double? = nil, text: String? = nil) -> Bool {
    guard let key = options.key else {
        FileHandle.standardError.write(Data("--key is required\n".utf8))
        exit(2)
    }
    var body: [String: Any] = ["key": key]
    if let number = number ?? options.number { body["number"] = number }
    if let text = text ?? options.text { body["text"] = text }
    if let unit = options.unit { body["unit"] = unit }
    if let history = options.history { body["history"] = history }

    guard body.count > 1 else {
        FileHandle.standardError.write(Data("provide --number or --text\n".utf8))
        exit(2)
    }
    guard let url = URL(string: "http://\(options.host):\(options.port)/api/push"),
          let payload = try? JSONSerialization.data(withJSONObject: body) else {
        return false
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = options.token {
        request.setValue(token, forHTTPHeaderField: "X-StatusBoard-Token")
    }
    request.httpBody = payload

    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error {
            FileHandle.standardError.write(Data("push failed: \(error.localizedDescription)\n".utf8))
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            FileHandle.standardError.write(Data("push failed: HTTP \(http.statusCode)\n".utf8))
        } else {
            success = true
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return success
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("""
    usage:
      sbctl push --key <key> (--number <n> | --text <s>) [--unit u] [--history n]
      sbctl pipe --key <key> [--interval seconds]
      options: --host <host> --port <port> --token <secret>
    """)
    exit(2)
}

let command = arguments[1]
let options = parseOptions(arguments.dropFirst(2))

switch command {
case "push":
    exit(push(options) ? 0 : 1)

case "pipe":
    var lastSent = Date.distantPast
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        if options.interval > 0, Date().timeIntervalSince(lastSent) < options.interval {
            continue
        }
        lastSent = Date()
        if let number = Double(trimmed) {
            push(options, number: number)
        } else {
            push(options, text: trimmed)
        }
    }
    exit(0)

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
    exit(2)
}
