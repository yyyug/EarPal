import Foundation

struct TranslationLanguage: Identifiable, Hashable {
    let id: String
    let displayName: String

    static let english = TranslationLanguage(id: "en", displayName: "English")
    static let traditionalChinese = TranslationLanguage(id: "zh-Hant", displayName: "Traditional Chinese")
    static let simplifiedChinese = TranslationLanguage(id: "zh-Hans", displayName: "Simplified Chinese")
    static let japanese = TranslationLanguage(id: "ja", displayName: "Japanese")
    static let korean = TranslationLanguage(id: "ko", displayName: "Korean")
    static let spanish = TranslationLanguage(id: "es", displayName: "Spanish")
    static let french = TranslationLanguage(id: "fr", displayName: "French")
    static let german = TranslationLanguage(id: "de", displayName: "German")

    static let commonOptions: [TranslationLanguage] = [
        .english,
        .traditionalChinese,
        .simplifiedChinese,
        .japanese,
        .korean,
        .spanish,
        .french,
        .german
    ]
}
