//
//  VoiceCoach.swift
//  Chess_PGN_TrainerApp
//

import AVFoundation
import NaturalLanguage
import SwiftUI
import AudioToolbox // Required for system sounds

@available(iOS 14.0, macOS 11.0, watchOS 7.0, tvOS 14.0, *)
@MainActor
public class VoiceCoach: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = VoiceCoach()
    
    // Using @Published ensures SwiftUI instantly redraws the toggle button when changed.
    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isVoiceCoachEnabled")
        }
    }
    
    private let synthesizer = AVSpeechSynthesizer()
    
    private override init() {
        // Load the saved state, which defaults to false (off) if it has never been set.
        self.isEnabled = UserDefaults.standard.bool(forKey: "isVoiceCoachEnabled")
        
        super.init()
        synthesizer.delegate = self
        
        // Configure AVAudioSession so it plays even if the physical silent switch is ON
        // mixWithOthers allows background music to keep playing while the voice speaks.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            print("❌ [VoiceCoach] Failed to setup AVAudioSession: \(error)")
        }
    }
    
    // MARK: - Audio Effects
    
    /// Plays a subtle "Tock" sound representing a piece hitting the board.
    public func playMoveSound() {
        guard isEnabled else { return } // Added to respect toggle state for sounds
        
        // System Sound 1306 is a short pop/tock.
        // If you ever add custom .wav files, you can replace this with AVAudioPlayer.
        AudioServicesPlaySystemSound(1306)
    }
    
    /// Plays an error "Bloop" sound for incorrect moves.
    public func playErrorSound() {
        guard isEnabled else { return } // Added to respect toggle state for sounds
        
        // System Sound 1053 is the standard error/fail thud.
        AudioServicesPlaySystemSound(1053)
    }
    
    // MARK: - Speech
    // NOTE: Text-To-Speech is currently shunted/commented out from usage in views 
    // for future use, but the implementation is retained below.
    
    /// Speaks the provided move and/or comment. Will interrupt whatever is currently playing.
    public func speak(move: String? = nil, comment: String? = nil, fallbackText: String? = nil) {
        guard isEnabled else { return }
        
        // Instantly stop current speech so fast-clickers don't get overlapping audio.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        var textToSpeak = ""
        var languageCode = "en-US" // Default to English
        
        // 1. Process the comment (Clean engine tags and detect language)
        var cleanComment = ""
        if let comment = comment, !comment.isEmpty {
            // Regex to remove all [%...] engine tags
            cleanComment = comment.replacingOccurrences(of: "\\[%[^\\]]+\\]", with: "", options: .regularExpression)
            
            // Regex to remove database statistics like "Games: 9234 (W: 50%, B:40%, D: 10%)"
            // This looks for the word "Games:" followed by numbers/commas, and then anything inside parentheses.
            cleanComment = cleanComment.replacingOccurrences(of: "Games:\\s*[0-9,]+\\s*\\([^)]+\\)", with: "", options: [.regularExpression, .caseInsensitive])
            
            // Regex to remove "eval: <number>" (e.g. "eval: +1.25", "eval: -M3", or "eval 0.5")
            cleanComment = cleanComment.replacingOccurrences(of: "eval\\s*[:=]?\\s*[+-]?[#0-9M.]+", with: "", options: [.regularExpression, .caseInsensitive])
            
            cleanComment = cleanComment.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !cleanComment.isEmpty {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(cleanComment)
                if let dominantLanguage = recognizer.dominantLanguage {
                    languageCode = dominantLanguage.rawValue
                }
            }
        }
        
        // 2. Process the move (Expand SAN notation to natural speech)
        if let move = move, !move.isEmpty {
            let expandedMove = languageCode.starts(with: "en") ? expandSAN(move) : move
            textToSpeak += expandedMove + ". "
        }
        
        // 3. Append the clean comment
        if !cleanComment.isEmpty {
            textToSpeak += cleanComment
        }
        
        // 4. Handle fallbacks
        if textToSpeak.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let fallback = fallbackText, !fallback.isEmpty {
                textToSpeak = fallback
            } else {
                return
            }
        }
        
        let utterance = AVSpeechUtterance(string: textToSpeak)
        
        // Try to hunt down an "Enhanced" or "Premium" voice to avoid the robotic sound
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        if let premiumVoice = allVoices.first(where: { voice in
            guard voice.language == languageCode else { return false }
            
            if #available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *) {
                return voice.quality == .premium || voice.quality == .enhanced
            } else {
                return voice.quality == .enhanced
            }
        }) {
            utterance.voice = premiumVoice
        } else if let defaultVoice = AVSpeechSynthesisVoice(language: languageCode) {
            utterance.voice = defaultVoice
        }
        
        // Tweak the pitch and rate slightly to make it sound slightly more natural
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.05
        
        synthesizer.speak(utterance)
    }
    
    /// Instantly stops the voice coach.
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
    
    // MARK: - String Expansion
    
    /// Translates raw Algebraic Notation into natural conversational English.
    private func expandSAN(_ san: String) -> String {
        var expanded = san
        
        if expanded.contains("O-O-O") || expanded.contains("0-0-0") {
            expanded = expanded.replacingOccurrences(of: "O-O-O", with: "Castles queenside")
            expanded = expanded.replacingOccurrences(of: "0-0-0", with: "Castles queenside")
        } else if expanded.contains("O-O") || expanded.contains("0-0") {
            expanded = expanded.replacingOccurrences(of: "O-O", with: "Castles kingside")
            expanded = expanded.replacingOccurrences(of: "0-0", with: "Castles kingside")
        }
        
        if let first = expanded.first {
            switch first {
            case "N": expanded = "Knight " + expanded.dropFirst()
            case "B": expanded = "Bishop " + expanded.dropFirst()
            case "R": expanded = "Rook " + expanded.dropFirst()
            case "Q": expanded = "Queen " + expanded.dropFirst()
            case "K": expanded = "King " + expanded.dropFirst()
            default: break
            }
        }
        
        expanded = expanded.replacingOccurrences(of: "x", with: " takes ")
        expanded = expanded.replacingOccurrences(of: "+", with: " check ")
        expanded = expanded.replacingOccurrences(of: "#", with: " checkmate ")
        expanded = expanded.replacingOccurrences(of: "=", with: " promotes to ")
        
        expanded = expanded.replacingOccurrences(of: "!!", with: " brilliant move ")
        expanded = expanded.replacingOccurrences(of: "!?", with: " interesting move ")
        expanded = expanded.replacingOccurrences(of: "?!", with: " dubious move ")
        expanded = expanded.replacingOccurrences(of: "??", with: " blunder ")
        expanded = expanded.replacingOccurrences(of: "!", with: " good move ")
        expanded = expanded.replacingOccurrences(of: "?", with: " mistake ")
        
        return expanded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
