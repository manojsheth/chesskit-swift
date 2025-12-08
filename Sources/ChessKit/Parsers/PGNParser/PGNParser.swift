//
//  PGNParser.swift
//  ChessKit
//

import Foundation

/// Parses and converts the Portable Game Notation (PGN)
/// of a chess game.
public enum PGNParser {

    // MARK: Public

    /// Parses a PGN string and returns a game.
    ///
    /// - parameter pgn: The PGN string of a chess game. This can be a single game or multiple games concatenated in the same string.
    /// - returns: A Swift representation of the chess game. If multiple games are provided, they will be merged into a single `Game` object.
    /// - throws: ``Error`` indicating the first error encountered while parsing `pgn`.
    ///
    /// The parsing implementation is based on the [PGN Standard](https://www.saremba.de/chessgml/standards/pgn/pgn-complete.htm)'s
    /// import format.
    ///
    /// The starting position is read from the `FEN` tag if
    /// the `SetUp` tag is set to `1`. Otherwise the standard
    /// starting position is assumed.
    ///
    /// If the `pgn` string contains multiple concatenated games, this function will parse all of them and merge them into a single `Game`.
    /// The tags of the first game are used. An error is thrown if subsequent games have a different starting position (FEN).
    public static func parse(game pgn: String) throws -> Game {
        let games = try parseIndividualGames(from: pgn)

        guard let firstGame = games.first else {
            return Game()
        }

        if games.count == 1 {
            return firstGame
        }

        var mergedGame = firstGame

        for gameToMerge in games.dropFirst() {
            try merge(source: gameToMerge, into: &mergedGame)
        }

        return mergedGame
    }

    /// Merges a source game's moves into a destination game.
    /// - Parameters:
    ///   - source: The `Game` containing the moves to merge.
    ///   - destination: The `Game` to merge the moves into. This game will be modified.
    /// - Throws: An error if the games do not share the same starting position.
    public static func merge(source: Game, into destination: inout Game) throws {
        guard source.startingPosition == destination.startingPosition else {
            throw Error.mismatchedStartingPosition
        }

        mergeMoves(
            from: source,
            into: &destination,
            sourceParentIndex: source.moves.startIndex,
            mergedParentIndex: destination.moves.startIndex
        )
    }

    /// Converts a ``Game`` object into a PGN string.
    ///
    /// - parameter game: The chess game to convert.
    /// - returns: A string containing the PGN of `game`.
    ///
    /// The conversion implementation is based on the [PGN Standard](https://www.saremba.de/chessgml/standards/pgn/pgn-complete.htm)'s
    /// export format.
    ///
    public static func convert(game: Game) -> String {
        var pgn = ""

        // tags

        game.tags.all
            .map(\.pgn)
            .filter { !$0.isEmpty }
            .forEach { pgn += $0 + "\n" }

        game.tags.other.sorted(by: <).forEach { key, value in
            pgn += "[\(key) \"\(value)\"]\n"
        }

        if !pgn.isEmpty {
            pgn += "\n"  // extra line between tags and movetext
        }

        // movetext

        for element in game.moves.pgnRepresentation {
            switch element {
            case let .whiteNumber(number):
                pgn += "\(number). "
            case let .blackNumber(number):
                pgn += "\(number)... "
            case let .move(move, _):
                pgn += movePGN(for: move)
            case let .positionAssessment(assessment):
                pgn += "\(assessment.rawValue) "
            case .variationStart:
                pgn += "("
            case .variationEnd:
                pgn = pgn.trimmingCharacters(in: .whitespaces)
                pgn += ") "
            }
        }

        pgn += game.tags.result

        return pgn.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Private

    /// Parses a string that may contain multiple PGNs and returns an array of `Game` objects.
    private static func parseIndividualGames(from pgn: String) throws -> [Game] {
        let sections = pgn.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.prefix(1) != "%" }
            .split(separator: "", omittingEmptySubsequences: true)
            .map(Array.init)

        var games: [Game] = []
        var currentSectionIndex = 0

        while currentSectionIndex < sections.count {
            let firstSection = sections[currentSectionIndex]

            let tagPairLines: [String]
            let moveTextLines: [String]

            // Check if the current section is a tag block.
            if firstSection.first?.hasPrefix("[") ?? false {
                tagPairLines = firstSection
                currentSectionIndex += 1
                if currentSectionIndex < sections.count {
                    moveTextLines = sections[currentSectionIndex]
                    currentSectionIndex += 1
                } else {
                    moveTextLines = [] // Tags without movetext.
                }
            } else {
                // No tag block, this section must be movetext.
                tagPairLines = []
                moveTextLines = firstSection
                currentSectionIndex += 1
            }

            let tags = try PGNTagParser.gameTags(from: tagPairLines.joined())
            var game = try MoveTextParser.game(
                from: moveTextLines.joined(separator: " "),
                startingPosition: try startingPosition(from: tags)
            )
            game.tags = tags
            games.append(game)
        }

        return games
    }

    /// Recursively merges moves from a source game into a destination game.
    private static func mergeMoves(from sourceGame: Game, into mergedGame: inout Game, sourceParentIndex: MoveTree.Index, mergedParentIndex: MoveTree.Index) {
        let sourceVariations = sourceGame.moves.variations(for: sourceParentIndex)

        for sourceMoveIndex in sourceVariations {
            guard let sourceMove = sourceGame.moves[sourceMoveIndex] else { continue }

            let existingMergedIndex = mergedGame.moves.nextIndex(containing: sourceMove, for: mergedParentIndex)
            let nextMergedIndex: MoveTree.Index

            if let existingIndex = existingMergedIndex {
                // The move already exists, so we merge annotations and comments.
                nextMergedIndex = existingIndex
                guard var existingMove = mergedGame.moves[existingIndex] else { continue }
                var needsUpdate = false

                // Merge comments
                if !sourceMove.comment.isEmpty {
                    let existingComments = existingMove.comment.components(separatedBy: "\n--\n")
                    let trimmedSourceComment = sourceMove.comment.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !existingComments.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSourceComment }) {
                        if existingMove.comment.isEmpty {
                            existingMove.comment = sourceMove.comment
                        } else {
                            existingMove.comment += "\n--\n\(sourceMove.comment)"
                        }
                        needsUpdate = true
                    }
                }

                // Merge annotations
                if sourceMove.assessment != .null && sourceMove.assessment != existingMove.assessment {
                    if existingMove.assessment == .null {
                        existingMove.assessment = sourceMove.assessment
                    } else {
                        let annotationText = "[\(sourceMove.assessment.rawValue)]"
                        if !existingMove.comment.contains(annotationText) {
                            if existingMove.comment.isEmpty {
                                existingMove.comment = annotationText
                            } else {
                                existingMove.comment += " \(annotationText)"
                            }
                        }
                    }
                    needsUpdate = true
                }

                if needsUpdate {
                    mergedGame.annotate(moveAt: existingIndex, assessment: existingMove.assessment, comment: existingMove.comment)
                }
            } else {
                // The move is new in this variation, so we add it.
                nextMergedIndex = mergedGame.make(move: sourceMove, from: mergedParentIndex)
            }

            // Recurse down this branch.
            mergeMoves(from: sourceGame, into: &mergedGame, sourceParentIndex: sourceMoveIndex, mergedParentIndex: nextMergedIndex)
        }
    }

    /// Generates starting position from `"SetUp"` and `"FEN"` tags.
    private static func startingPosition(
        from tags: Game.Tags
    ) throws -> Position {
        if tags.setUp == "1", let position = FENParser.parse(fen: tags.fen) {
            position
        } else if tags.setUp == "0" || (tags.setUp.isEmpty && tags.fen.isEmpty) {
            .standard
        } else {
            throw Error.invalidSetUpOrFEN
        }
    }

    /// Generates PGN string for the given `move` including assessments
    /// and comments.
    private static func movePGN(for move: Move) -> String {
        var result = ""

        result += "\(move.san) "

        if move.assessment != .null {
            result += "\(move.assessment.rawValue) "
        }

        if !move.comment.isEmpty {
            result += "{\(move.comment)} "
        }

        return result
    }

}

// MARK: - Error
extension PGNParser {
    /// Possible errors returned by `PGNParser`.
    ///
    /// These errors are thrown when issues are encountered
    /// while scanning and parsing the provided PGN text.
    public enum Error: Swift.Error, Equatable {
        /// There are too many line breaks in the provided PGN.
        /// PGN should contain a single blank line between the
        /// tags and move text. This error is now typically superseded by more specific parsing errors.
        case tooManyLineBreaks
        /// The starting positions of multiple PGNs being merged
        /// do not match based on their FEN tags.
        case mismatchedStartingPosition
        /// If included in the PGN's tag pairs, the `SetUp` tag must
        /// be set to either `"0"` or `"1"`.
        ///
        /// If `"0"`, the `FEN` tag must be blank. If `1`, the
        /// `FEN` tag must contain a valid FEN string representing
        /// the starting position of the game.
        ///
        /// - seealso: ``FENParser``
        case invalidSetUpOrFEN

        // MARK: Tags
        /// Tags must be surrounded by brackets with an unquoted
        /// string (key) followed by a quoted string (value) inside.
        ///
        /// For example: `[Round "29"]`
        case invalidTagFormat
        /// Tags must have an open bracket (`[`) and a close bracket (`]`).
        /// If there is a close bracket without an open, this error
        /// will be thrown.
        case mismatchedTagBrackets
        /// Tag string (value) could not be parsed.
        case tagStringNotFound
        /// Tag symbol (key) could not be parsed.
        case tagSymbolNotFound
        /// Tag symbols must be either letters, numbers, or underscores (`_`).
        case unexpectedTagCharacter(String)

        // MARK: Move Text
        /// The move or position assessment annotation is invalid.
        case invalidAnnotation(String)
        /// The move SAN is invalid for the implied position given
        /// by its location within the PGN string.
        case invalidMove(san: String, fen: String, moveSequence: String)
        /// The first item in a move text string must be either a
        /// number (e.g. `1.`) or a move SAN (e.g. `e4`).
        case unexpectedMoveTextToken
        /// Comments must be enclosed on both sides by braces (`{`, `}`).
        case unpairedCommentDelimiter
        /// Variations must be enclosed on both sides by parentheses (`(`, `)`).
        case unpairedVariationDelimiter
    }
}
