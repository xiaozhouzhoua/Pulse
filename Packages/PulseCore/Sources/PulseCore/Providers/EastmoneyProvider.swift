import Foundation

/// Eastmoney intraday history (push2his.eastmoney.com, unofficial API) and
/// Chinese-language business profiles (emweb F10, unofficial API).
///
/// Wired for two gaps: the Shanghai Gold Exchange's Au99.99 has no intraday
/// history anywhere else — Sina quotes it but publishes no series, and the
/// exchange's own intraday file serves the previous session — and the F10
/// pages are the only Chinese-language business summaries for A-shares and
/// HK stocks, which Yahoo cannot answer in any language.
///
/// Eastmoney bans an IP for hours after a burst of requests — measured, not
/// assumed — so this provider deliberately declares **charts and profiles
/// only**. That keeps it out of quote polling entirely: it is asked for data
/// when a chart opens, a sparkline refreshes on its five-minute timer, or a
/// profile page is opened (each answer cached for the day), and never on the
/// quote tick. If it does get blocked, the circuit breaker parks it and the
/// daily history from the exchange still draws.
public struct EastmoneyProvider: QuoteProvider {
    public static let providerID = "eastmoney"

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.providerID,
            name: PulseLocalization.localizedString("provider.eastmoney"),
            markets: [.metalCN, .sh, .sz, .hk],
            capabilities: [.candles, .profile],
            candleMarkets: [.metalCN],
            candlePeriods: [.minute1, .minute5, .minute15, .minute30, .hour1],
            delay: [.metalCN: 0],
            // Deliberately slow: this source answers charts, and pacing it is
            // what keeps it available at all.
            rateLimit: RateLimitPolicy(minInterval: 3)
        )
    }

    /// Eastmoney addresses everything as `<market>.<code>`; 118 is the Shanghai
    /// Gold Exchange.
    static func secid(for metal: PreciousMetalID) -> String? {
        switch metal {
        case .shanghaiGoldSpot: "118.AU9999"
        case .gold, .goldSpot, .silver, .silverSpot, .platinum, .palladium,
             .shanghaiGold, .shanghaiSilver: nil
        }
    }

    /// `klt` is Eastmoney's period code.
    static func klt(for period: CandlePeriod) -> Int? {
        switch period {
        case .minute1: 1
        case .minute5: 5
        case .minute15: 15
        case .minute30: 30
        case .hour1: 60
        case .day: 101
        case .week: 102
        case .month: 103
        }
    }

    // MARK: - QuoteProvider

    public func search(_ query: String) async throws -> [SymbolInfo] {
        throw ProviderError.unsupported(.search)
    }

    /// Charts only — see the note on this type.
    public func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        throw ProviderError.unsupported(.quotes)
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        guard let metal = symbol.metalID,
              let secid = Self.secid(for: metal),
              let klt = Self.klt(for: period) else {
            throw ProviderError.unsupported(.candles)
        }

        var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")!
        components.queryItems = [
            .init(name: "secid", value: secid),
            .init(name: "klt", value: String(klt)),
            .init(name: "fqt", value: "0"),
            .init(name: "beg", value: "0"),
            .init(name: "end", value: "20500101"),
            .init(name: "lmt", value: String(max(count, 1))),
            .init(name: "fields1", value: "f1,f2"),
            .init(name: "fields2", value: "f51,f52,f53,f54,f55,f56"),
        ]
        let data = try await http.get(
            components.url!,
            headers: ["Referer": "https://quote.eastmoney.com/"]
        )
        // A blocked request answers 200 with an empty body rather than an error.
        guard !data.isEmpty else {
            throw ProviderError.rateLimited
        }

        let candles = try Self.parseCandles(data, intraday: period.isIntraday)
        guard !candles.isEmpty else {
            throw ProviderError.badResponse("eastmoney: no candles parsed for \(secid)")
        }
        return Array(candles.suffix(count))
    }

    // MARK: - Profile

    /// The F10 host addresses A-shares as SH/SZ + code and HK stocks as a
    /// zero-padded five-digit code; other markets have no F10 pages.
    static func profileCode(for symbol: SymbolID) -> String? {
        switch symbol.market {
        case .sh: "SH\(symbol.code)"
        case .sz: "SZ\(symbol.code)"
        case .hk: symbol.paddedCode(width: 5)
        default: nil
        }
    }

    /// Chinese-language business summary from the F10 pages. A symbol the F10
    /// does not describe (or a market it does not cover) answers `nil` — that
    /// is an answer, so the composite can still ask another source.
    public func profile(for symbol: SymbolID) async throws -> SecurityProfile? {
        guard let code = Self.profileCode(for: symbol) else {
            throw ProviderError.unsupported(.profile)
        }
        let path = symbol.market == .hk
            ? "PC_HKF10/CompanyProfile/PageAjax"
            : "PC_HSF10/CompanySurvey/PageAjax"
        var components = URLComponents(string: "https://emweb.securities.eastmoney.com/\(path)")!
        components.queryItems = [.init(name: "code", value: code)]
        let data = try await http.get(
            components.url!,
            headers: ["Referer": "https://emweb.securities.eastmoney.com/"]
        )
        return try Self.parseProfile(data, symbol: symbol)
    }

    // MARK: - Profile parsing

    /// A-share survey: `{"jbzl":[{"ORG_PROFILE":"…","EM2016":"食品饮料-饮料-白酒",
    /// "INDUSTRYCSRC1":"制造业-…"}]}`.
    struct SurveyResponse: Decodable {
        struct Item: Decodable {
            let orgProfile: String?
            let em2016: String?
            let industryCSRC1: String?

            enum CodingKeys: String, CodingKey {
                case orgProfile = "ORG_PROFILE"
                case em2016 = "EM2016"
                case industryCSRC1 = "INDUSTRYCSRC1"
            }
        }
        let jbzl: [Item]?
    }

    /// HK company profile: `{"gszl":{"gsjs":"…","sshy":"软件服务"}}`.
    struct CompanyProfileResponse: Decodable {
        struct Company: Decodable {
            let gsjs: String?
            let sshy: String?
        }
        let gszl: Company?
    }

    static func parseProfile(_ data: Data, symbol: SymbolID) throws -> SecurityProfile? {
        let summary: String?
        let sector: String?
        let industry: String?
        do {
            if symbol.market == .hk {
                let decoded = try JSONDecoder().decode(CompanyProfileResponse.self, from: data)
                summary = decoded.gszl?.gsjs
                sector = decoded.gszl?.sshy
                industry = nil
            } else {
                let decoded = try JSONDecoder().decode(SurveyResponse.self, from: data)
                let item = decoded.jbzl?.first
                summary = item?.orgProfile
                // EM2016 is a one-level-to-three-level chain ("食品饮料-饮料-白酒");
                // the ends name the sector and the niche the market files it under.
                (sector, industry) = Self.classification(from: item?.em2016)
                    ?? (nil, item?.industryCSRC1)
            }
        } catch {
            throw ProviderError.badResponse("eastmoney: \(error.localizedDescription)")
        }
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return SecurityProfile(
            symbol: symbol,
            summary: trimmed,
            sector: sector,
            industry: industry,
            localeIdentifier: "zh-Hans"
        )
    }

    /// Splits the Eastmoney industry chain into its first and last levels.
    static func classification(from chain: String?) -> (String?, String?)? {
        guard let chain else { return nil }
        let parts = chain.split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty else { return nil }
        let first = parts[0]
        let last = parts.count > 1 ? parts[parts.count - 1] : nil
        return (first, last == first ? nil : last)
    }

    // MARK: - Parsing

    /// `{"data":{"klines":["2026-08-20 09:30,971.81,972.00,972.00,971.81,20", …]}}`
    /// where the fields are time, open, **close**, high, low, volume — Eastmoney
    /// puts close second, which is not the order the rest of the app uses.
    static func parseCandles(_ data: Data, intraday: Bool) throws -> [Candle] {
        struct Response: Decodable {
            struct Payload: Decodable { let klines: [String]? }
            let data: Payload?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.badResponse("eastmoney: \(error.localizedDescription)")
        }
        guard let rows = response.data?.klines else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Market.metalCN.timeZone
        formatter.dateFormat = intraday ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"

        return rows.compactMap { row -> Candle? in
            let f = row.components(separatedBy: ",")
            guard f.count >= 6,
                  let time = formatter.date(from: f[0]),
                  let open = Double(f[1]), let close = Double(f[2]),
                  let high = Double(f[3]), let low = Double(f[4]),
                  close > 0 else { return nil }
            return Candle(
                time: time, open: open, high: high, low: low, close: close,
                volume: Double(f[5]).flatMap { $0 > 0 ? $0 : nil }
            )
        }
        .sorted { $0.time < $1.time }
    }
}
