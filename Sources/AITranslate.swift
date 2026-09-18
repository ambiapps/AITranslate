//
//  AITranslate.swift
//
//
//  Created by Paul MacRory on 3/7/24.
//

import ArgumentParser
import OpenAI
import Foundation

@main
struct AITranslate: AsyncParsableCommand {
  static let systemPrompt =
    """
    You are a translator tool that translates UI strings for a software application.
    Your inputs will be a source language, a target language, the original text, and
    optionally some context to help you understand how the original text is used within
    the application. Each piece of information will be inside some XML-like tags.
    In your response include *only* the translation, and do not include any metadata, tags, 
    periods, quotes, or new lines, unless included in the original text.
    """

  static func gatherLanguages(from input: String) -> [String] {
    input.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespaces) }
  }

  @Argument(transform: URL.init(fileURLWithPath:))
  var inputFile: URL

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("A comma separated list of language codes (must match the language codes used by xcstrings)"), 
    transform: AITranslate.gatherLanguages(from:)
  )
  var languages: [String]

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("Your OpenAI API key, see: https://platform.openai.com/api-keys")
  )
  var openAIKey: String

  @Flag(name: .shortAndLong)
  var verbose: Bool = false

  @Flag(
    name: .shortAndLong,
    help: ArgumentHelp("By default a backup of the input will be created. When this flag is provided, the backup is skipped.")
  )
  var skipBackup: Bool = false

  @Flag(
    name: .shortAndLong,
    help: ArgumentHelp("Forces all strings to be translated, even if an existing translation is present.")
  )
  var force: Bool = false

  @Option(
    name: .long,
    help: ArgumentHelp("Stops after translating this many strings (each into every requested language), saving the progress so far. Run again to continue.")
  )
  var limit: Int?

  /// A run of failures this long means the API is down or out of credits, so the rest
  /// would fail as well.
  static let maximumConsecutiveFailures = 20

  lazy var openAI: OpenAI = {
    let configuration = OpenAI.Configuration(
      token: openAIKey,
      organizationIdentifier: nil,
      timeoutInterval: 60.0
    )

    return OpenAI(configuration: configuration)
  }()

  var numberOfTranslationsProcessed = 0
  var numberOfRequests = 0
  var numberOfConsecutiveFailures = 0

  mutating func run() async throws {
    do {
      let dict = try JSONDecoder().decode(
        StringsDict.self,
        from: try Data(contentsOf: inputFile)
      )

      let totalNumberOfTranslations = dict.strings.count * languages.count
      let start = Date()
      var previousPercentage: Int = -1
      var numberOfStringsTranslated = 0
      var stoppedEarly = false

      // Sorted so that a `--limit`ed run picks the same strings every time.
      for entry in dict.strings.sorted(by: { $0.key < $1.key }) {
        let numberOfRequestsBefore = numberOfRequests

        try await processEntry(
          key: entry.key,
          localizationGroup: entry.value,
          sourceLanguage: dict.sourceLanguage
        )

        let fractionProcessed = (Double(numberOfTranslationsProcessed) / Double(totalNumberOfTranslations))
        let percentageProcessed = Int(fractionProcessed * 100)

        // Print the progress at 10% intervals.
        if percentageProcessed != previousPercentage, percentageProcessed % 10 == 0 {
          print("[⏳] \(percentageProcessed)%")
          previousPercentage = percentageProcessed
        }

        numberOfTranslationsProcessed += languages.count

        if numberOfRequests > numberOfRequestsBefore {
          numberOfStringsTranslated += 1
        }

        if numberOfConsecutiveFailures >= Self.maximumConsecutiveFailures {
          print("[❌] \(numberOfConsecutiveFailures) translations failed in a row, giving up")
          stoppedEarly = true
          break
        }

        if let limit, numberOfStringsTranslated >= limit {
          print("[⏸️] Reached the limit of \(limit) strings")
          stoppedEarly = true
          break
        }
      }

      try save(dict)

      let formatter = DateComponentsFormatter()
      formatter.allowedUnits = [.hour, .minute, .second]
      formatter.unitsStyle = .full
      let formattedString = formatter.string(from: Date().timeIntervalSince(start))!

      print("\(stoppedEarly ? "[💾] Saved progress" : "[✅] 100%") \n[⏰] Translations time: \(formattedString)")
    } catch let error {
      throw error
    }
  }

  mutating func processEntry(
    key: String,
    localizationGroup: LocalizationGroup,
    sourceLanguage: String
  ) async throws {
    for lang in languages {
      let localizationEntries = localizationGroup.localizations ?? [:]
      let unit = localizationEntries[lang]

      // Nothing to do.
      if let unit, unit.hasTranslation, force == false {
        continue
      }

      // Skip the ones with variations/substitutions since they are not supported.
      if let unit, unit.isSupportedFormat == false {
        print("[⚠️] Unsupported format in entry with key: \(key)")
        continue
      }

      // The source text can either be the key or an explicit value in the `localizations`
      // dictionary keyed by `sourceLanguage`.
      let sourceText = localizationEntries[sourceLanguage]?.stringUnit?.value ?? key

      // A failed translation leaves the entry as it was, so that it is picked up
      // again by the next run instead of being saved as an empty "error" unit.
      guard let result = try await performTranslation(
        sourceText,
        from: sourceLanguage,
        to: lang,
        context: localizationGroup.comment,
        openAI: openAI
      ) else {
        continue
      }

      localizationGroup.localizations = localizationEntries
      localizationGroup.localizations?[lang] = LocalizationUnit(
        stringUnit: StringUnit(
          state: "translated",
          value: result
        )
      )
    }
    localizationGroup.localizations?[sourceLanguage] = LocalizationUnit(
      stringUnit: StringUnit(
        state: "translated",
        value: key))
  }

  func save(_ dict: StringsDict) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let data = try encoder.encode(dict)

    try backupInputFileIfNecessary()
    try data.write(to: inputFile)
  }

  func backupInputFileIfNecessary() throws {
    if skipBackup == false {
      let backupFileURL = inputFile.appendingPathExtension("original")

      try? FileManager.default.trashItem(
        at: backupFileURL,
        resultingItemURL: nil
      )

      try FileManager.default.moveItem(
        at: inputFile,
        to: backupFileURL
      )
    }
  }

  mutating func performTranslation(
    _ text: String,
    from source: String,
    to target: String,
    context: String? = nil,
    openAI: OpenAI
  ) async throws -> String? {

    // Skip text that is generally not translated.
    if text.isEmpty ||
        text.trimmingCharacters(
          in: .whitespacesAndNewlines
            .union(.symbols)
            .union(.controlCharacters)
        ).isEmpty {
      return text
    }

    var translationRequest = "<source>\(source)</source>"
    translationRequest += "<target>\(target)</target>"
    translationRequest += "<original>\(text)</original>"

    if let context {
      translationRequest += "<context>\(context)</context>"
    }

    let query = ChatQuery(
      messages: [
        .init(role: .system, content: Self.systemPrompt)!,
        .init(role: .user, content: translationRequest)!
      ],
      model: .gpt4_o
    )

    numberOfRequests += 1

    do {
      let result = try await openAI.chats(query: query)
      let translation = result.choices.first?.message.content?.string ?? text
      numberOfConsecutiveFailures = 0

      if verbose {
        print("[\(target)] " + text + " -> " + translation)
      }

      return translation
    } catch let error {
      numberOfConsecutiveFailures += 1
      print("[❌] Failed to translate \(text) into \(target)")

      if verbose {
        print("[💥]" + error.localizedDescription)
      }

      return nil
    }
  }
}
