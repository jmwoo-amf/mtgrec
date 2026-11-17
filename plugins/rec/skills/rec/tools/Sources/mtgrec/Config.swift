import Foundation

/// 사용자별 설정. `/rec setup` 이 `~/.config/mtgrec/config.json` 에 쓴다.
///
/// 바이너리가 읽는 것은 `storage` 하나다. 나머지 필드(Notion · 참석자 · 문체)는
/// 스킬과 요약 에이전트가 읽는다. 모르는 필드는 무시하므로 스킬 쪽 필드를 늘려도
/// 다시 빌드할 필요가 없다.
struct Config: Decodable {
    var storage: String?

    /// `$HOME`. Foundation 의 홈 디렉터리는 환경 변수를 무시하고 계정 정보를 읽으므로
    /// 테스트에서 HOME 을 바꿔도 따라오지 않는다. 그래서 환경 변수를 먼저 본다.
    static var home: URL {
        if let value = ProcessInfo.processInfo.environment["HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~` 로 시작하는 경로를 `home` 기준으로 편다.
    static func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    /// 설정 디렉터리. `MTGREC_CONFIG_DIR` 로 바꿀 수 있다 (테스트용).
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["MTGREC_CONFIG_DIR"], !override.isEmpty {
            return expand(override)
        }
        return home.appendingPathComponent(".config/mtgrec", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static let shared: Config = {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write("mtgrec: \(fileURL.path) 를 읽을 수 없어 기본값을 씁니다: \(error)\n".data(using: .utf8)!)
            return Config()
        }
    }()

    /// 설정이 없을 때의 저장 위치.
    static let defaultStorage = "~/Recordings/mtgrec"
}

/// 스킬 references 파일(`correct.md` · `live-summary.md`)을 찾는다.
///
/// 바이너리는 `~/.claude/bin` 에 홀로 복사되므로 자기 옆에서 찾을 수 없다.
/// 스킬이 `~/.claude/skills/rec` 에 있을 수도, plugin 캐시에 있을 수도 있어서
/// 순서대로 본다. 사용자가 설정 디렉터리에 같은 이름의 파일을 두면 그것이 이긴다.
enum References {
    static func find(_ name: String, envKey: String) -> URL? {
        let home = Config.home
        var candidates: [URL] = []
        if let value = ProcessInfo.processInfo.environment[envKey], !value.isEmpty {
            candidates.append(Config.expand(value))
        }
        candidates.append(Config.directory.appendingPathComponent(name))
        candidates.append(home.appendingPathComponent(".claude/skills/rec/references/\(name)"))
        candidates.append(contentsOf: pluginCandidates(name))

        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return url
            }
        }
        return nil
    }

    static func load(_ name: String, envKey: String) -> String? {
        guard let url = find(name, envKey: envKey) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `~/.claude/plugins/cache/{marketplace}/{plugin}/{version}/skills/rec/references/{name}`.
    /// 버전 디렉터리가 여럿 남아 있을 수 있으므로 최근에 바뀐 것부터 준다.
    private static func pluginCandidates(_ name: String) -> [URL] {
        let fm = FileManager.default
        let cache = Config.home.appendingPathComponent(".claude/plugins/cache")
        var found: [(URL, Date)] = []
        for marketplace in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            for plugin in (try? fm.contentsOfDirectory(at: marketplace, includingPropertiesForKeys: nil)) ?? [] {
                for version in (try? fm.contentsOfDirectory(at: plugin, includingPropertiesForKeys: nil)) ?? [] {
                    let url = version.appendingPathComponent("skills/rec/references/\(name)")
                    if let attributes = try? fm.attributesOfItem(atPath: url.path),
                       let modified = attributes[.modificationDate] as? Date {
                        found.append((url, modified))
                    }
                }
            }
        }
        return found.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
