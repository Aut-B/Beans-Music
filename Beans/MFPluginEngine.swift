import Foundation
import JavaScriptCore

// MARK: - MusicFree 插件引擎
//
// 在 JavaScriptCore 里承载 MusicFree 兼容的插件沙箱。
//
// 设计要点（沿用 Kumone dev-musicfree 分支的成熟实现）：
// - 一个 JSContext 承载全部插件（与上游 RN 版一致：所有插件共享一个 Hermes 全局）。
// - 所有 JS 访问都在 `queue` 上串行化；异步 JS 调用通过空 evaluateScript 检查点
//   抽干 JSC 的 microtask 队列，同时 URLSession 回调也回到同一队列 —— 抽水泵本身
//   不阻塞队列，所以回调不会把队列锁死。

enum MFPluginEngineError: LocalizedError {
    case runtimeNotReady
    case timeout
    case script(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady: return beansLocalized("插件引擎未就绪", "Plugin engine not ready")
        case .timeout: return beansLocalized("插件调用超时", "Plugin call timed out")
        case .script(let message): return message
        }
    }
}

final class MFPluginEngine {
    static let shared = MFPluginEngine()

    private let context: JSContext
    private let queue = DispatchQueue(label: "com.beans.app.plugin-engine", qos: .userInitiated)
    private let session: URLSession
    private var runtimeLoaded = false
    private let state = EngineState()

    /// 最近的插件 HTTP 请求，供 App 内日志排查。
    struct RequestLogEntry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let method: String
        let url: String
        let status: Int
        let size: Int
    }

    private var requestLog: [RequestLogEntry] = []

    /// JS 调用失败记录（"platform.method: error"），最新在前。
    private var callLog: [String] = []

    func snapshotRequestLog() async -> [RequestLogEntry] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: requestLog)
            }
        }
    }

    func snapshotCallLog() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: callLog)
            }
        }
    }

    private func appendCallLog(_ message: String) {
        callLog.insert("[\(BeansLogger.dateString(Date()))] \(message)", at: 0)
        if callLog.count > 40 { callLog.removeLast(callLog.count - 40) }
    }

    /// 各插件 userVariables 的存放目录，由 MFPluginManager 在使用前设置。
    private var variablesDirectory: URL?

    private final class EngineState {
        var lastJSException: String?
    }

    private final class CallState {
        var result: String?
        var done = false
    }

    private init() {
        context = JSContext()!
        context.name = "BeansMusicFreePluginEngine"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        let stateBox = state
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "unknown"
            BeansLogger.shared.log("插件 JS 异常：\(message)", level: .debug)
            stateBox.lastJSException = message
        }
        loadRuntime()
    }

    // MARK: - 运行时装载

    /// JS 库装载顺序有依赖：先底层库，再运行时胶水层，最后注入原生桥。
    /// 注意文件名的 `mf-lib-` 前缀是刻意的：仓库 .gitignore 有 `_*.js` 规则，
    /// 沿用上游的 `__mf_lib_*.js` 命名会被忽略而进不了构建产物。
    /// 库导出的全局名（`globalThis.__mf_lib_xxx`）写在各文件内部，与文件名无关。
    private static let runtimeFiles = [
        "crypto-js.js",
        "dayjs.js",
        "qs.js",
        "he.js",
        "big-integer.js",
        "mf-lib-cheerio.js",
        "mf-lib-webdav.js",
        "mf-lib-whatwgurl.js",
        "url-fallback.js",
        "mf-lib-compare-versions.js",
        "mf-plugin-runtime.js",
    ]

    private func loadRuntime() {
        queue.sync {
            for file in Self.runtimeFiles {
                guard let url = Bundle.main.url(forResource: file, withExtension: nil),
                      let code = try? String(contentsOf: url, encoding: .utf8) else {
                    BeansLogger.shared.log("插件运行时缺少资源：\(file)", level: .error)
                    continue
                }
                context.evaluateScript(code, withSourceURL: url)
            }

            // 原生桥（block 可直接被 JS 调用）
            let httpRequest: @convention(block) (String, JSValue) -> Void = { [weak self] optionsJSON, completion in
                self?.handleHTTPRequest(optionsJSON: optionsJSON, completion: completion)
            }
            context.setObject(httpRequest, forKeyedSubscript: "__mf_nativeHttpRequest" as NSString)

            let getVariables: @convention(block) (String) -> [String: Any] = { [weak self] platform in
                self?.storedVariables(for: platform) ?? [:]
            }
            context.setObject(getVariables, forKeyedSubscript: "__mf_nativeGetUserVariables" as NSString)

            let setVariables: @convention(block) (String, String) -> Void = { [weak self] platform, json in
                self?.storeVariables(json, for: platform)
            }
            context.setObject(setVariables, forKeyedSubscript: "__mf_nativeSetUserVariables" as NSString)

            let logLine: @convention(block) (String, String) -> Void = { level, message in
                BeansLogger.shared.log("[插件:\(level)] \(message)", level: .debug)
            }
            context.setObject(logLine, forKeyedSubscript: "__mf_nativeLog" as NSString)

            context.evaluateScript("""
            globalThis.__mf_native = {
              httpRequest: function (optionsJSON, cb) { __mf_nativeHttpRequest(optionsJSON, cb); },
              getUserVariables: function (platform) { return __mf_nativeGetUserVariables(platform); },
              setUserVariables: function (platform, json) { __mf_nativeSetUserVariables(platform, json); },
            };
            """)
            runtimeLoaded = true
            BeansLogger.shared.log("MusicFree 插件运行时已装载", level: .info)
        }
    }

    // MARK: - 存储钩子

    func setVariablesDirectory(_ url: URL) {
        queue.sync { variablesDirectory = url }
    }

    private func storedVariables(for platform: String) -> [String: Any] {
        guard let dir = variablesDirectory else { return [:] }
        let url = dir.appendingPathComponent(platform + ".json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func storeVariables(_ json: String, for platform: String) {
        guard let dir = variablesDirectory else { return }
        let url = dir.appendingPathComponent(platform + ".json")
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let serialized = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? serialized.write(to: url, options: .atomic)
        }
    }

    // MARK: - HTTP 桥

    private func handleHTTPRequest(optionsJSON: String, completion: JSValue) {
        guard let data = optionsJSON.data(using: .utf8),
              let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = options["url"] as? String,
              let url = Self.robustPluginURL(urlString) else {
            respond(completion, withError: "invalid request options")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        let headerDict = options["headers"] as? [String: String] ?? [:]
        if !headerDict.isEmpty {
            for (key, value) in headerDict {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = options["data"] as? String {
            // 运行时对二进制请求体做了 base64 编码并打了 data-encoding 标
            let encoding = (headerDict["data-encoding"] ?? headerDict["Data-Encoding"] ?? "").lowercased()
            if encoding == "base64" {
                request.httpBody = Data(base64Encoded: body, options: [.ignoreUnknownCharacters])
            } else {
                request.httpBody = body.data(using: .utf8)
            }
        }
        // 插件传入的 timeout 是以毫秒计的 axios 语义（默认 2000），直接用会让正常请求
        // 频繁超时；这里沿用 session 级别的 12 秒，交由插件自身的重试/降级逻辑处理。
        _ = (options["timeout"] as? NSNumber)?.doubleValue

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: [String: Any]
            if let error {
                result = ["error": error.localizedDescription]
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String {
                        headers[k.lowercased()] = v
                    }
                }
                var body = ""
                if let data,
                   let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    body = decoded
                }
                result = [
                    "status": http.statusCode,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                    "headers": headers,
                    "body": body,
                ]
            } else {
                result = ["error": "invalid response"]
            }
            let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "{}"
            self?.queue.async {
                // 调试日志：只保留最近 80 条
                if let http = response as? HTTPURLResponse {
                    self?.requestLog.append(RequestLogEntry(
                        timestamp: Date(),
                        method: request.httpMethod ?? "GET",
                        url: request.url?.absoluteString ?? "",
                        status: http.statusCode,
                        size: data?.count ?? 0
                    ))
                    if let count = self?.requestLog.count, count > 80 {
                        self?.requestLog.removeFirst(count - 80)
                    }
                }
                completion.call(withArguments: [json])
            }
        }
        task.resume()
    }

    private func respond(_ completion: JSValue, withError message: String) {
        queue.async {
            completion.call(withArguments: ["{\"error\":\"\(message)\"}"])
        }
    }

    /// 宽容地构造 URL。插件里常出现格式化占位符（`view?%s`），
    /// Foundation 会因裸 `%s` 拒绝解析（RN 的网络层会做百分号转义）。
    /// 这里先转义非法的百分号序列，再退回 URLComponents 与整体百分号编码。
    static func robustPluginURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        let sanitized = raw.replacingOccurrences(
            of: "%(?![0-9a-fA-F]{2})",
            with: "%25",
            options: .regularExpression
        )
        if let url = URL(string: sanitized), url.scheme != nil { return url }
        if let url = URLComponents(string: sanitized)?.url, url.scheme != nil { return url }
        return URL(string: sanitized.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sanitized)
    }

    // MARK: - JS 求值

    /// 把 Swift 字符串渲染成 JS 字符串字面量。
    /// 注意：这里**不能**用 JSONSerialization —— 裸 String 不是合法的 JSON
    /// 顶层类型，Foundation 会抛无法桥接的 NSException，在穿过 JS block 边界时崩溃。
    private func jsString(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""   // "
            case 0x5C: output += "\\\\"   // backslash
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0x09: output += "\\t"
            case 0x08: output += "\\b"
            case 0x0C: output += "\\f"
            case 0x2028: output += "\\u2028"
            case 0x2029: output += "\\u2029"
            case 0x00 ... 0x1F: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }

    /// 执行 `script`，其中 `__CALLBACK__` 会被替换成回调名；
    /// 反复抽干 JSC 微任务队列，直到回调触发或超时。
    private func evaluateWithCallback(_ script: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                guard runtimeLoaded else {
                    continuation.resume(throwing: MFPluginEngineError.runtimeNotReady)
                    return
                }
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let callbackName = "__mf_done_\(token)"
                let state = CallState()
                let callback: @convention(block) (String) -> Void = { json in
                    state.result = json
                    state.done = true
                }
                context.setObject(callback, forKeyedSubscript: callbackName as NSString)
                let deadline = Date().addingTimeInterval(timeout)

                context.evaluateScript(script.replacingOccurrences(of: "__CALLBACK__", with: callbackName))

                func pump() {
                    if state.done {
                        context.setObject(nil, forKeyedSubscript: callbackName as NSString)
                        if let result = state.result {
                            continuation.resume(returning: result)
                        } else {
                            continuation.resume(throwing: MFPluginEngineError.script("empty callback result"))
                        }
                        return
                    }
                    if Date() > deadline {
                        context.setObject(nil, forKeyedSubscript: callbackName as NSString)
                        continuation.resume(throwing: MFPluginEngineError.timeout)
                        return
                    }
                    // 空求值 = 一个 JSC 微任务检查点，推进挂起的 promise
                    _ = context.evaluateScript("void 0")
                    queue.asyncAfter(deadline: .now() + .milliseconds(2), execute: pump)
                }
                pump()
            }
        }
    }

    // MARK: - 对外 API

    /// 挂载插件代码，返回其声明的 platform 与 userVariables。
    /// `__mf_mountPlugin` 是**同步** JS 函数、直接返回 JSON 字符串，
    /// 因此这里读返回值即可（走异步回调的夹具只会超时）。
    func mount(code: String, installName: String) async throws -> MFPluginMountResult {
        let script = "__mf_mountPlugin(\(jsString(code)), \(jsString(installName)))"
        let resultJSON: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                guard runtimeLoaded else {
                    continuation.resume(throwing: MFPluginEngineError.runtimeNotReady)
                    return
                }
                let value = context.evaluateScript(script)?.toString() ?? ""
                continuation.resume(returning: value)
            }
        }
        guard let data = resultJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let detail = state.lastJSException.map { "（\($0)）" } ?? ""
            throw MFPluginEngineError.script(beansLocalized("插件加载结果解析失败", "Failed to parse mount result") + detail)
        }
        guard object["ok"] as? Bool == true,
              let platform = object["platform"] as? String, !platform.isEmpty else {
            throw MFPluginEngineError.script((object["error"] as? String) ?? beansLocalized("插件加载失败", "Plugin failed to load"))
        }
        let variables = (object["userVariables"] as? [[String: Any]]) ?? []
        return MFPluginMountResult(platform: platform, userVariables: variables)
    }

    /// 调用已挂载插件的 `method(args...)`，返回 JSON 值。
    func call(platform: String, method: String, args: [Any], timeout: TimeInterval = 25) async throws -> Any? {
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let script = "__mf_callNamed(\(jsString(platform)), \(jsString(method)), \(jsString(argsJSON)), __CALLBACK__)"
        let resultJSON = try await evaluateWithCallback(script, timeout: timeout)
        guard let data = resultJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MFPluginEngineError.script("call result parse failed")
        }
        guard object["ok"] as? Bool == true else {
            let message = (object["error"] as? String) ?? beansLocalized("插件返回错误", "Plugin returned an error")
            queue.async { [self] in
                appendCallLog("\(platform).\(method): \(message)")
            }
            throw MFPluginEngineError.script(message)
        }
        return object["value"]
    }
}
