import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
public final class VoiceAudioPreviewer {
    public private(set) var playingVoiceId: String?
    public private(set) var lastError: String?

    private var player: AVAudioPlayer?
    private var delegateProxy: PlayerDelegateProxy?

    public init() {}

    public func play(voiceId: String, wavData: Data) {
        stop()
        lastError = nil
        do {
            let newPlayer = try AVAudioPlayer(data: wavData)
            let proxy = PlayerDelegateProxy { [weak self] in
                Task { @MainActor in
                    if self?.playingVoiceId == voiceId {
                        self?.playingVoiceId = nil
                        self?.player = nil
                    }
                }
            }
            newPlayer.delegate = proxy
            newPlayer.prepareToPlay()
            if newPlayer.play() {
                self.player = newPlayer
                self.delegateProxy = proxy
                self.playingVoiceId = voiceId
            } else {
                self.lastError = "无法启动音频播放。"
            }
        } catch {
            self.lastError = "音频解码失败：\(error.localizedDescription)"
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        delegateProxy = nil
        playingVoiceId = nil
    }
}

private final class PlayerDelegateProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onComplete: @Sendable () -> Void

    init(onComplete: @escaping @Sendable () -> Void) {
        self.onComplete = onComplete
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onComplete()
    }
}
