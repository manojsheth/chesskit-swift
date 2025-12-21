//
//  PGNParser.swift
//  ChessKit
//

import Foundation

/// Parses and converts the Portable Game Notation (PGN)
/// of a chess game.
public enum PGNParser {

    // MARK: Public

    /// Parses a PGN string that may contain multiple games, merging them where possible.
    ///
    /// - parameter pgn: The PGN string of a chess game. This can be a single game or multiple games concatenated in the same string.
    /// - returns: A tuple containing the primary `mergedGame` and an array of any `unmergedGames`.
    /// - throws: ``Error`` indicating the first error encountered while parsing `pgn`.
    ///
    /// This function is suitable for parsing PGN data from external sources that may contain multiple games. It will parse all of them
    /// and merge them into a single `Game` object where possible. The tags of the first game are used.
    ///
    /// After attempting to merge all games into the first game, any remaining unmerged games will be consolidated amongst themselves
    /// and returned in the `unmergedGames` array.
    public static func parsePotentialMultipleGames(pgn: String) throws -> (mergedGame: Game, unmergedGames: [Game]) {
        let games = try parseIntoGames(from: pgn)

        guard let firstGame = games.first else {
            return (mergedGame: Game(), unmergedGames: [])
        }

        if games.count == 1 {
            return (mergedGame: firstGame, unmergedGames: [])
        }

        var mergedGame = firstGame
        var gamesToMerge = Array(games.dropFirst())
        var unmergedCountInPreviousPass = -1

        while !gamesToMerge.isEmpty {
            if gamesToMerge.count == unmergedCountInPreviousPass {
                // No merges were successful in a full pass.
                // Consolidate the remaining games amongst themselves and return.
                let finalUnmergedGames = try consolidate(games: gamesToMerge)
                return (mergedGame: mergedGame, unmergedGames: finalUnmergedGames)
            }
            unmergedCountInPreviousPass = gamesToMerge.count

            var stillUnmerged: [Game] = []
            for gameToMerge in gamesToMerge {
                do {
                    try merge(source: gameToMerge, into: &mergedGame)
                } catch Error.mergePointNotFound {
                    stillUnmerged.append(gameToMerge)
                }
            }
            gamesToMerge = stillUnmerged
        }

        return (mergedGame: mergedGame, unmergedGames: [])
    }

    /// Parses a PGN string that is expected to contain a single game.
    ///
    /// - parameter pgn: The PGN string of a single chess game.
    /// - returns: A Swift representation of the chess game.
    /// - throws: ``Error`` if parsing fails or if the `pgn` string contains more than one game.
    ///
    /// This function should be used when you are certain the PGN source contains exactly one game,
    /// for example, when reading from a file that your app has previously saved.
    public static func parse(pgn: String) throws -> Game {
        let games = try parseIntoGames(from: pgn)

        guard games.count <= 1 else {
            throw Error.multipleGamesInSingleGameParser
        }

        return games.first ?? Game()
    }

    /// Merges a source game's moves into a destination game.
    /// - Parameters:
    ///   - source: The `Game` containing the moves to merge.
    ///   - destination: The `Game` to merge the moves into. This game will be modified.
    /// - Throws: An error if the games do not share the same starting position, or if a merge point cannot be found for different starting positions.
    public static func merge(source: Game, into destination: inout Game) throws {
        guard let sourceStartingPosition = source.startingPosition,
              let destinationStartingPosition = destination.startingPosition else {
            // A game must have a starting position to be merged.
            return
        }

        // Case 1: The source game starts from the same board state as the destination game.
        if sourceStartingPosition.hasSameBoardState(as: destinationStartingPosition) {
            // Merge root comment
            if let sourceRootComment = source.moves.dictionary[source.startingIndex]?.move.comment, !sourceRootComment.isEmpty {
                if let destRootMove = destination.moves.dictionary[destination.startingIndex]?.move {
                    let existingComment = destRootMove.comment
                    let newComment = existingComment.isEmpty ? sourceRootComment : "\(existingComment)\n--\n\(sourceRootComment)"
                    destination.annotate(moveAt: destination.startingIndex, comment: newComment)
                }
            }
            // Merge moves from the root.
            mergeMoves(
                from: source,
                into: &destination,
                sourceParentIndex: source.startingIndex,
                mergedParentIndex: destination.startingIndex
            )
            return
        }

        // Case 2: Source game starts from a position found within the destination game.
        // Search for a matching position in the destination game.
        let mergePoint = destination.positions.first { (_, position) in
            position.hasSameBoardState(as: sourceStartingPosition)
        }

        guard let (mergeIndex, _) = mergePoint else {
            // No merge point found. Throw error so it can be re-queued.
            throw Error.mergePointNotFound
        }

        // A merge point was found. Now merge comments and moves.
        // 1. Merge source's root comment into the move leading to the merge point.
        if let sourceRootComment = source.moves.dictionary[source.startingIndex]?.move.comment, !sourceRootComment.isEmpty {
            if let destinationMove = destination.moves[mergeIndex] {
                let existingComment = destinationMove.comment
                let newComment = existingComment.isEmpty ? sourceRootComment : "\(existingComment)\n--\n\(sourceRootComment)"
                destination.annotate(moveAt: mergeIndex, assessment: destinationMove.assessment, comment: newComment)
            }
        }

        // 2. Merge moves recursively, starting from the merge point.
        mergeMoves(
            from: source,
            into: &destination,
            sourceParentIndex: source.startingIndex,
            mergedParentIndex: mergeIndex
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

    /// Consolidates a list of games by merging them into each other where possible.
    private static func consolidate(games: [Game]) throws -> [Game] {
        guard !games.isEmpty else { return [] }

        var remainingGames = games
        var consolidatedGames: [Game] = []

        while !remainingGames.isEmpty {
            var baseGame = remainingGames.removeFirst()
            var gamesToTryMerging = remainingGames
            var unmergedThisRound: [Game] = []
            var wasMergeSuccessfulInPass = true

            // Keep merging into baseGame until a full pass results in no merges.
            while wasMergeSuccessfulInPass {
                wasMergeSuccessfulInPass = false
                unmergedThisRound = []

                for gameToMerge in gamesToTryMerging {
                    do {
                        try merge(source: gameToMerge, into: &baseGame)
                        wasMergeSuccessfulInPass = true // A merge happened!
                    } catch Error.mergePointNotFound {
                        unmergedThisRound.append(gameToMerge)
                    }
                }
                gamesToTryMerging = unmergedThisRound
            }

            consolidatedGames.append(baseGame)
            remainingGames = gamesToTryMerging
        }

        return consolidatedGames
    }

    /// Parses a string that may contain multiple PGNs and returns an array of `Game` objects.
    private static func parseIntoGames(from pgn: String) throws -> [Game] {
        let lines = pgn.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.starts(with: "%") }

        var games: [Game] = []
        var pendingComment: String?

        var tagPairLines: [String] = []
        var moveTextLines: [String] = []

        // Helper to process the collected lines into a game object.
        func processCurrentGame() throws {
            // Do nothing if no lines have been collected.
            if tagPairLines.isEmpty && moveTextLines.isEmpty {
                return
            }

            let tags = try PGNTagParser.gameTags(from: tagPairLines.joined(separator: "\n"))
            var game = try MoveTextParser.game(
                from: moveTextLines.joined(separator: " "),
                startingPosition: try startingPosition(from: tags)
            )
            game.tags = tags

            if game.moves.isEmpty {
                // This is an empty game (e.g., just tags, or movetext is just "*").
                // If it has a root comment, we'll carry it over.
                let startingComment = game.moves.dictionary[game.startingIndex]?.move.comment ?? ""
                if !startingComment.isEmpty {
                    if let existingComment = pendingComment {
                        pendingComment = "\(existingComment)\n--\n\(startingComment)"
                    } else {
                        pendingComment = startingComment
                    }
                }
            } else {
                // This is a valid game with moves.
                if let commentToApply = pendingComment {
                    let existingComment = game.moves.dictionary[game.startingIndex]?.move.comment ?? ""

                    let newComment = existingComment.isEmpty
                        ? commentToApply
                        : "\(commentToApply)\n--\n\(existingComment)"

                    game.annotate(moveAt: game.startingIndex, comment: newComment)
                    pendingComment = nil
                }
                games.append(game)
            }
            
            // Reset for the next game.
            tagPairLines.removeAll()
            moveTextLines.removeAll()
        }

        var isParsingMoveText = false

        for line in lines {
            if line.starts(with: "[") {
                if isParsingMoveText {
                    // We've hit a new game's tags, so process the previous one.
                    try processCurrentGame()
                    isParsingMoveText = false
                }
                tagPairLines.append(line)
            } else if !line.isEmpty {
                // It's a movetext line.
                isParsingMoveText = true
                moveTextLines.append(line)
            } else { // line is empty
                // An empty line after tags and before movetext is the separator.
                if !tagPairLines.isEmpty && moveTextLines.isEmpty {
                    isParsingMoveText = true
                } 
                // If we are already parsing movetext, an empty line is considered part of it
                // to handle cases like comments separated by blank lines.
                else if isParsingMoveText {
                    moveTextLines.append(line)
                }
            }
        }

        try processCurrentGame() // Process the last game in the PGN.

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
        @available(*, deprecated, message: "This error is no longer thrown. Use mergePointNotFound instead.")
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
        /// A merge point could not be found for a sub-game in a multi-game PGN.
        /// This is used internally to re-queue games for merging.
        case mergePointNotFound
        /// The PGN string was expected to contain a single game, but multiple were found.
        case multipleGamesInSingleGameParser

        // MARK: Tags
        /// Tags must be surrounded by brackets with an unquoted
        /// string (key) followed by a quoted string (value) inside.
        ///
        ///for example: `[Round "29"]`
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
