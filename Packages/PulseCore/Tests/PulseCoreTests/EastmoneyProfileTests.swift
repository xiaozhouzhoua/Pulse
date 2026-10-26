import Foundation
import Testing
@testable import PulseCore

/// Eastmoney's F10 pages are the only Chinese-language business summaries for
/// A-shares and HK stocks; the parser decides whether a Chinese reader sees a
/// description or an "unavailable" page.
@Suite("Eastmoney profile parsing")
struct EastmoneyProfileTests {
    private let aShareJSON = """
    {"jbzl":[{"SECUCODE":"600519.SH","ORG_PROFILE":"  贵州茅台酒股份有限公司成立于1999年。\\n  公司主营茅台酒。","EM2016":"食品饮料-饮料-白酒","INDUSTRYCSRC1":"制造业-酒、饮料和精制茶制造业"}]}
    """

    private let hkJSON = """
    {"zqzl":{"zqdm":"00700.HK"},"gszl":{"gsmc":"腾讯控股有限公司","gsjs":"  腾讯控股有限公司是一家世界领先的互联网科技公司。","sshy":"软件服务"}}
    """

    @Test("An A-share survey yields the Chinese summary and the industry chain ends")
    func aShareSurvey() throws {
        let symbol = SymbolID(market: .sh, code: "600519")
        let profile = try #require(try EastmoneyProvider.parseProfile(Data(aShareJSON.utf8), symbol: symbol))
        #expect(profile.summary == "贵州茅台酒股份有限公司成立于1999年。\n  公司主营茅台酒。" || profile.summary.hasPrefix("贵州茅台酒股份有限公司"))
        #expect(profile.sector == "食品饮料")
        #expect(profile.industry == "白酒")
        #expect(profile.localeIdentifier == "zh-Hans")
    }

    @Test("An HK company profile yields the summary and its industry")
    func hkProfile() throws {
        let symbol = SymbolID(market: .hk, code: "700")
        let profile = try #require(try EastmoneyProvider.parseProfile(Data(hkJSON.utf8), symbol: symbol))
        #expect(profile.summary.hasPrefix("腾讯控股有限公司"))
        #expect(profile.sector == "软件服务")
        #expect(profile.industry == nil)
        #expect(profile.localeIdentifier == "zh-Hans")
    }

    @Test("A blank summary is an answer, not an error")
    func blankSummary() throws {
        let symbol = SymbolID(market: .sh, code: "600519")
        let json = #"{"jbzl":[{"ORG_PROFILE":"   ","EM2016":"食品饮料"}]}"#
        let profile = try EastmoneyProvider.parseProfile(Data(json.utf8), symbol: symbol)
        #expect(profile == nil)
    }

    @Test("The industry chain splits into its first and last levels")
    func industryChain() {
        let chain = EastmoneyProvider.classification(from: "食品饮料-饮料-白酒")
        #expect(chain?.0 == "食品饮料")
        #expect(chain?.1 == "白酒")
        let single = EastmoneyProvider.classification(from: "软件服务")
        #expect(single?.0 == "软件服务")
        #expect(single?.1 == nil)
        #expect(EastmoneyProvider.classification(from: "") == nil)
        #expect(EastmoneyProvider.classification(from: nil) == nil)
    }

    @Test("Only the markets with F10 pages are addressed")
    func profileCodes() {
        #expect(EastmoneyProvider.profileCode(for: SymbolID(market: .sh, code: "600519")) == "SH600519")
        #expect(EastmoneyProvider.profileCode(for: SymbolID(market: .sz, code: "000858")) == "SZ000858")
        #expect(EastmoneyProvider.profileCode(for: SymbolID(market: .hk, code: "700")) == "00700")
        #expect(EastmoneyProvider.profileCode(for: SymbolID(market: .us, code: "AAPL")) == nil)
    }
}

/// The composite routes descriptions by the app's language first: a Chinese
/// reader gets the Chinese source even when an English one ranks higher for
/// quotes, and a source with nothing to say never starves one that has.
/// Serialized: the tests share UserDefaults.standard's language preference,
/// which parallel runs would flip under each other.
@Suite("Composite profile routing", .serialized)
struct CompositeProfileRoutingTests {
    private func setLanguage(_ preference: PulseLanguagePreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: PulseLocalization.languagePreferenceKey)
    }

    private func restoreLanguage() {
        UserDefaults.standard.removeObject(forKey: PulseLocalization.languagePreferenceKey)
    }

    private func zhProfile(_ symbol: SymbolID) -> SecurityProfile {
        SecurityProfile(symbol: symbol, summary: "中文简介", localeIdentifier: "zh-Hans")
    }

    private func enProfile(_ symbol: SymbolID) -> SecurityProfile {
        SecurityProfile(symbol: symbol, summary: "English summary", localeIdentifier: "en")
    }

    @Test("A Chinese reader is answered by the Chinese source")
    func chineseFirst() async throws {
        setLanguage(.simplifiedChinese)
        defer { restoreLanguage() }
        let symbol = SymbolID(market: .sh, code: "600519")
        var zhSource = MockProvider(id: EastmoneyProvider.providerID, supportsProfile: true)
        zhSource.profileResult = zhProfile(symbol)
        var enSource = MockProvider(id: "yahoo", supportsProfile: true)
        enSource.profileResult = enProfile(symbol)

        let composite = CompositeProvider(providers: [enSource, zhSource])
        let profile = try #require(await composite.profile(for: symbol))
        #expect(profile.summary == "中文简介")
    }

    @Test("An English reader is answered by the English source")
    func englishFirst() async throws {
        setLanguage(.english)
        defer { restoreLanguage() }
        let symbol = SymbolID(market: .sh, code: "600519")
        var zhSource = MockProvider(id: EastmoneyProvider.providerID, supportsProfile: true)
        zhSource.profileResult = zhProfile(symbol)
        var enSource = MockProvider(id: "yahoo", supportsProfile: true)
        enSource.profileResult = enProfile(symbol)

        let composite = CompositeProvider(providers: [enSource, zhSource])
        let profile = try #require(await composite.profile(for: symbol))
        #expect(profile.summary == "English summary")
    }

    @Test("A source with nothing to say hands the question to the next")
    func emptyAnswerFallsThrough() async throws {
        setLanguage(.english)
        defer { restoreLanguage() }
        let symbol = SymbolID(market: .sh, code: "600519")
        // The English source ranks first but has no write-up; the Chinese
        // source's summary is still better than no page at all.
        let enSource = MockProvider(id: "yahoo", supportsProfile: true)
        var zhSource = MockProvider(id: EastmoneyProvider.providerID, supportsProfile: true)
        zhSource.profileResult = zhProfile(symbol)

        let composite = CompositeProvider(providers: [enSource, zhSource])
        let profile = try #require(await composite.profile(for: symbol))
        #expect(profile.summary == "中文简介")
    }
}
