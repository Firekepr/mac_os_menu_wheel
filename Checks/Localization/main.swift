import Foundation

// Run this executable from an app bundle containing both localization folders.
let expectedLanguage = CommandLine.arguments.last!
let isPortuguese = expectedLanguage == "pt"
precondition(L10n.text("Escolha um app") == (isPortuguese ? "Escolha um app" : "Choose an app"))
precondition(L10n.text("Fechar %@", "IntelliJ IDEA") == (isPortuguese ? "Fechar IntelliJ IDEA" : "Quit IntelliJ IDEA"))
precondition(L10n.text("%@ de %@ aplicativos abertos na roda.", "3", "5") ==
             (isPortuguese ? "3 de 5 aplicativos abertos na roda." : "3 of 5 running apps in the wheel."))
let resources = Bundle.main.resourceURL!
let english = NSDictionary(contentsOf: resources.appendingPathComponent("en.lproj/Localizable.strings")) as! [String: String]
let portuguese = NSDictionary(contentsOf: resources.appendingPathComponent("pt.lproj/Localizable.strings")) as! [String: String]
precondition(Set(english.keys) == Set(portuguese.keys))
for key in english.keys {
    let count = key.components(separatedBy: "%@").count
    precondition(english[key]!.components(separatedBy: "%@").count == count)
    precondition(portuguese[key]!.components(separatedBy: "%@").count == count)
}
print("Localization checks passed: \(expectedLanguage), \(english.count) keys, formatted names and counts.")
