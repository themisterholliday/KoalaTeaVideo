//
//  AssetPlayer.swift
//  KoalaTeaPlayer
//
//  Created by Craig Holliday on 9/26/17.
//

import Foundation
import AVFoundation
import MediaPlayer
import SwifterSwift

public protocol AssetPlayerDelegate: class {
    // Setup
    func currentAssetDidChange(_ player: AssetPlayer)
    func playerIsSetup(_ player: AssetPlayer)

    // Playback
    func playerPlaybackStateDidChange(_ player: AssetPlayer)
    func playerCurrentTimeDidChange(_ player: AssetPlayer)
    /// Current time change but in milliseconds
    func playerCurrentTimeDidChangeInMilliseconds(_ player: AssetPlayer)
    func playerPlaybackDidEnd(_ player: AssetPlayer)

    // Buffering
    func playerIsLikelyToKeepUp(_ player: AssetPlayer)
    // This is the time in seconds that the video has been buffered.
    // If implementing a UIProgressView, user this value / player.maximumDuration to set progress.
    func playerBufferTimeDidChange(_ player: AssetPlayer)
}

public enum AssetPlayerPlaybackState: Equatable {
    case setup(asset: AssetProtocol)
    case playing, paused, interrupted, buffering, finished, none
    case failed(error: Error?)

    public static func == (lhs: AssetPlayerPlaybackState, rhs: AssetPlayerPlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.setup(let lKey), .setup(let rKey)):
            return lKey.urlAsset.url == rKey.urlAsset.url
        case (.playing, .playing):
            return true
        case (.paused, .paused):
            return true
        case (.interrupted, .interrupted):
            return true
        case (.failed(_), .failed(_)):
            return true
        case (.buffering, .buffering):
            return true
        case (.finished, .finished):
            return true
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

/*
 KVO context used to differentiate KVO callbacks for this class versus other
 classes in its class hierarchy.
 */
private var AssetPlayerKVOContext = 0

extension AssetPlayer {
    private struct Constants {
        // Keys required for a playable item
        static let AssetKeysRequiredToPlay = [
            "playable",
            "hasProtectedContent"
        ]
    }

    public static var defaultLocalPlayer: AssetPlayer {
        return AssetPlayer(isPlayingLocalAsset: true, shouldLoop: true)
    }

    public static var defaultRemotePlayer: AssetPlayer {
        return AssetPlayer(isPlayingLocalAsset: true, shouldLoop: true)
    }
}

open class AssetPlayer: NSObject {
    /// Player delegate.
    public weak var delegate: AssetPlayerDelegate?

    // MARK: Options
    private var isPlayingLocalAsset: Bool
    private var shouldLoop: Bool
    private var _startTimeForLoop: Double = 0
    public var startTimeForLoop: Double {
        return self._startTimeForLoop
    }
    private var _endTimeForLoop: Double? = nil
    public var endTimeForLoop: Double? {
        return self._endTimeForLoop
    }
    public var isMuted: Bool {
        return self.player.isMuted
    }

    // Mark: Time Properties
    public var currentTime: Double = 0

    public var bufferedTime: Double = 0 {
        didSet {
            self.delegate?.playerBufferTimeDidChange(self)
        }
    }

    public var timeElapsedText: String = ""
    public var durationText: String = ""

    public var timeLeftText: String {
        let timeLeft = duration - currentTime
        return self.createTimeString(time: timeLeft)
    }

    public var maxSecondValue: Float = 0

    public var duration: Double {
        guard let currentItem = player.currentItem else { return 0.0 }

        return currentItem.duration.seconds
    }

    public var rate: Float = 1.0 {
        willSet {
            guard newValue != self.rate else { return }
        }
        didSet {
            player.rate = rate
            self.setAudioTimePitch(by: rate)
        }
    }

    // MARK: AV Properties

    /// AVPlayer to pass in to any PlayerView's
    @objc public let player = AVPlayer()

    private var currentAVAudioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain {
        willSet {
            guard newValue != self.currentAVAudioTimePitchAlgorithm else { return }
        }
        didSet {
            self.avPlayerItem?.audioTimePitchAlgorithm = self.currentAVAudioTimePitchAlgorithm
        }
    }

    private func setAudioTimePitch(by rate: Float) {
        guard rate <= 2.0 else {
            self.currentAVAudioTimePitchAlgorithm = .spectral
            return
        }
        self.currentAVAudioTimePitchAlgorithm = .timeDomain
    }

    private var avPlayerItem: AVPlayerItem? = nil {
        willSet {
            if avPlayerItem != nil {
                // Remove observers before changing player item
                self.removePlayerItemObservers()
            }
        }
        didSet {
            if avPlayerItem != nil {
                self.addPlayerItemObservers()
            }
            /*
             If needed, configure player item here before associating it with a player.
             (example: adding outputs, setting text style rules, selecting media options)
             */
            player.replaceCurrentItem(with: self.avPlayerItem)
        }
    }

    private var asset: AssetProtocol? {
        didSet {
            guard let newAsset = self.asset else { return }

            asynchronouslyLoadURLAsset(newAsset)
        }
    }

    // MARK: Observers
    /*
     A token obtained from calling `player`'s `addPeriodicTimeObserverForInterval(_:queue:usingBlock:)`
     method.
     */
    private var timeObserverToken: Any?

    /*
     A token obtained from calling `player`'s `addPeriodicTimeObserverForInterval(_:queue:usingBlock:)`
     method.
     */
    private var timeObserverTokenMilliseconds: Any?

    private var playbackBufferEmptyObserver: NSKeyValueObservation?
    private var playbackLikelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?


    public var previousState: AssetPlayerPlaybackState

    /// The state that the internal `AVPlayer` is in.
    public var state: AssetPlayerPlaybackState {
        willSet {
            guard state != newValue else { return }
        }
        didSet {
            self.previousState = oldValue
            self.handleStateChange(state)
        }
    }

    // MARK: - Life Cycle
    public init(isPlayingLocalAsset: Bool, shouldLoop: Bool) {
        self.state = .none
        self.previousState = .none
        self.isPlayingLocalAsset = isPlayingLocalAsset
        self.shouldLoop = shouldLoop
    }

    deinit {
        if let timeObserverToken = timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        if let timeObserverTokenMilliseconds = timeObserverTokenMilliseconds {
            player.removeTimeObserver(timeObserverTokenMilliseconds)
            self.timeObserverTokenMilliseconds = nil
        }

        player.pause()

        removePlayerObservers()

        if avPlayerItem != nil {
            self.removePlayerItemObservers()
        }
    }

    // MARK: - Asset Loading
    private func asynchronouslyLoadURLAsset(_ newAsset: AssetProtocol) {
        /*
         Using AVAsset now runs the risk of blocking the current thread (the
         main UI thread) whilst I/O happens to populate the properties. It's
         prudent to defer our work until the properties we need have been loaded.
         */
        newAsset.urlAsset.loadValuesAsynchronously(forKeys: Constants.AssetKeysRequiredToPlay) {
            /*
             The asset invokes its completion handler on an arbitrary queue.
             To avoid multiple threads using our internal state at the same time
             we'll elect to use the main thread at all times, let's dispatch
             our handler to the main queue.
             */
            DispatchQueue.main.async {
                /*
                 `self.asset` has already changed! No point continuing because
                 another `newAsset` will come along in a moment.
                 */
                guard newAsset.urlAsset == self.asset?.urlAsset else { return }

                // @TODO: Handle errors
                /*
                 Test whether the values of each of the keys we need have been
                 successfully loaded.
                 */
                for key in Constants.AssetKeysRequiredToPlay {
                    var error: NSError?

                    if newAsset.urlAsset.statusOfValue(forKey: key, error: &error) == .failed {
                        let stringFormat = NSLocalizedString("error.asset_key_%@_failed.description", comment: "Can't use this AVAsset because one of it's keys failed to load")
                        let _ = String.localizedStringWithFormat(stringFormat, key)

                        self.state = .failed(error: error as Error?)

                        return
                    }
                }

                // We can't play this asset.
                if !newAsset.urlAsset.isPlayable || newAsset.urlAsset.hasProtectedContent {
                    let message = NSLocalizedString("error.asset_not_playable.description", comment: "Can't use this AVAsset because it isn't playable or has protected content")

                    let error = NSError(domain: message, code: -1, userInfo: nil) as Error
                    self.state = .failed(error: error)

                    return
                }

                /*
                 We can play this asset. Create a new `AVPlayerItem` and make
                 it our player's current item.
                 */
                self.avPlayerItem = AVPlayerItem(asset: newAsset.urlAsset)
                self.delegate?.currentAssetDidChange(self)
                self.delegate?.playerIsSetup(self)

                if self.state != .playing, self.state != .paused, self.state != .buffering {
                    self.state = .none
                }

            }
        }
    }

    // MARK: Playback Control Methods.
    open func perform(action: AssetPlayerActions) {
        switch action {
        case .setup(let asset, let startMuted):
            self.setup(with: asset)
            self.player.isMuted = startMuted
        case .play:
            self.state = .playing
        case .pause:
            self.state = .paused
        case .seekToTimeInSeconds(let time):
            self.seekToTimeInSeconds(time) { _ in }
        case .changePlayerPlaybackRate(let rate):
            self.changePlayerPlaybackRate(to: rate)
        case .changeIsPlayingLocalAsset(let isPlayingLocalAsset):
            self.isPlayingLocalAsset = isPlayingLocalAsset
        case .changeShouldLoop(let shouldLoop):
            self.shouldLoop = shouldLoop
        case .changeStartTimeForLoop(let time):
            guard time > 0 else {
                self._startTimeForLoop = 0
                return
            }
            self._startTimeForLoop = time
        case .changeEndTimeForLoop(let time):
            guard self.duration != 0 else {
                return
            }

            guard time < self.duration else {
                self._endTimeForLoop = self.duration
                return
            }
            self._endTimeForLoop = time
        case .changeIsMuted(let isMuted):
            self.player.isMuted = isMuted
        }
    }

    // MARK: Time Formatting
    /*
     A formatter for individual date components used to provide an appropriate
     value for the `startTimeLabel` and `durationLabel`.
     */
    // Lazy init time formatter because create a formatter multiple times is expensive
    lazy var timeRemainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.zeroFormattingBehavior = .pad
        formatter.allowedUnits = [.minute, .second]

        return formatter
    }()

    private func createTimeString(time: Double) -> String {
        let components = NSDateComponents()
        components.second = Int(max(0.0, time))

        return timeRemainingFormatter.string(from: components as DateComponents)!
    }
}

// MARK: State Management Methods
extension AssetPlayer {
    private func handleStateChange(_ state: AssetPlayerPlaybackState) {
        switch state {
        case .none:
            self.player.pause()
        case .setup(let asset):
            self.asset = asset
        case .playing:
            if #available(iOS 10.0, *) {
                self.player.playImmediately(atRate: self.rate)
            } else {
                // Fallback on earlier versions
                self.player.rate = self.rate
                self.player.play()
            }
        case .paused:
            self.player.pause()
        case .interrupted:
            self.player.pause()
        case .failed:
            self.player.pause()
        case .buffering:
            self.player.pause()
        case .finished:
            self.player.pause()

            guard !shouldLoop else {
                self.currentTime = startTimeForLoop
                self.seekToTimeInSeconds(startTimeForLoop) { _ in
                    self.state = .playing
                }
                return
            }
        }

        self.delegate?.playerPlaybackStateDidChange(self)
    }

    // MARK: - KVO Observation
    override open func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // Make sure the this KVO callback was intended for this view controller.
        guard context == &AssetPlayerKVOContext else {
//            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if keyPath == #keyPath(AssetPlayer.player.currentItem.duration) {
            // @TODO: Better handle this guard
            guard let _ = self.avPlayerItem else { return }
            // Update timeSlider and enable/disable controls when duration > 0.0

            /*
             Handle `NSNull` value for `NSKeyValueChangeNewKey`, i.e. when
             `player.currentItem` is nil.
             */
            let newDuration: CMTime
            if let newDurationAsValue = change?[NSKeyValueChangeKey.newKey] as? NSValue {
                newDuration = newDurationAsValue.timeValue
            }
            else {
                newDuration = CMTime.zero
            }

            let hasValidDuration = newDuration.isNumeric && newDuration.value != 0
            let newDurationSeconds = hasValidDuration ? CMTimeGetSeconds(newDuration) : 0.0
            let currentTime = hasValidDuration ? player.currentTime().seconds : 0.0

            self.maxSecondValue = Float(newDurationSeconds)
            self.timeElapsedText = createTimeString(time: currentTime)
            self.durationText = createTimeString(time: newDurationSeconds)
        }
        else if keyPath == #keyPath(AssetPlayer.player.rate) {
            // Handle any player rate changes
        }
        else if keyPath == #keyPath(AssetPlayer.player.currentItem.status) {
            // Display an error if status becomes `.Failed`.

            /*
             Handle `NSNull` value for `NSKeyValueChangeNewKey`, i.e. when
             `player.currentItem` is nil.
             */
            let newStatus: AVPlayerItem.Status

            if let newStatusAsNumber = change?[NSKeyValueChangeKey.newKey] as? NSNumber {
                newStatus = AVPlayerItem.Status(rawValue: newStatusAsNumber.intValue)!
            }
            else {
                newStatus = .unknown
            }

            if newStatus == .failed {
                self.state = .failed(error: player.currentItem?.error)
            }
        }
        // All Buffer observer values
        else if keyPath == #keyPath(AVPlayerItem.isPlaybackBufferEmpty) {
            self.handleBufferEmptyChange()
        }
        else if keyPath == #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp) {
            self.handleLikelyToKeepUpChange()
        }
        else if keyPath == #keyPath(AVPlayerItem.loadedTimeRanges) {
            self.handleLoadedTimeRangesChange()
        }
    }

    // Trigger KVO for anyone observing our properties affected by player and player.currentItem
    override open class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String> {
        let affectedKeyPathsMappingByKey: [String: Set<String>] = [
            "duration":     [#keyPath(AssetPlayer.player.currentItem.duration)],
            "rate":         [#keyPath(AssetPlayer.player.rate)]
        ]

        return affectedKeyPathsMappingByKey[key] ?? super.keyPathsForValuesAffectingValue(forKey: key)
    }

    // MARK: Notification Observing Methods
    @objc private func handleAVPlayerItemDidPlayToEndTimeNotification(notification: Notification) {
        guard !shouldLoop else {
            self.currentTime = startTimeForLoop
            self.seekToTimeInSeconds(startTimeForLoop) { _ in
                self.state = .playing
            }
            return
        }

        self.delegate?.playerPlaybackDidEnd(self)
        self.state = .finished
    }
}

extension AssetPlayer {
    private func setup(with asset: AssetProtocol) {
        /*
         Update the UI when these player properties change.
         
         Use the context parameter to distinguish KVO for our particular observers
         and not those destined for a subclass that also happens to be observing
         these properties.
         */
        self.addPlayerObservers()

        self.state = .setup(asset: asset)

        // Seconds time observer
        let interval = CMTimeMake(value: 1, timescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let strongSelf = self else { return }

            guard strongSelf.state != .finished else { return }

            let timeElapsed = time.seconds

            strongSelf.currentTime = timeElapsed
            strongSelf.timeElapsedText = strongSelf.createTimeString(time: timeElapsed)

            strongSelf.delegate?.playerCurrentTimeDidChange(strongSelf)
        }

        // Millisecond time observer
        let millisecondInterval = CMTimeMake(value: 1, timescale: 100)
        timeObserverTokenMilliseconds = player.addPeriodicTimeObserver(forInterval: millisecondInterval, queue: DispatchQueue.main) { [weak self] time in
            guard let strongSelf = self else { return }

            guard strongSelf.state != .finished else { return }

            let timeElapsed = time.seconds

            strongSelf.currentTime = timeElapsed
            strongSelf.timeElapsedText = strongSelf.createTimeString(time: timeElapsed)

            strongSelf.delegate?.playerCurrentTimeDidChangeInMilliseconds(strongSelf)

            // Set finished state if we are looping and passed our loop end time
            if let endTime = strongSelf.endTimeForLoop, timeElapsed >= endTime, strongSelf.shouldLoop {
                strongSelf.state = .finished
            }
        }
    }

    private func seekTo(_ newPosition: CMTime) {
        guard asset != nil else { return }
        self.player.seek(to: newPosition, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
    }

    private func seekToTimeInSeconds(_ time: Double, completion: @escaping (Bool) -> Void) {
        guard asset != nil else { return }
        let newPosition = CMTimeMakeWithSeconds(time, preferredTimescale: 1000)
        self.player.seek(to: newPosition, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero, completionHandler: completion)
    }

    private func changePlayerPlaybackRate(to newRate: Float) {
        guard asset != nil else { return }
        self.rate = newRate
    }
}

// @TODO: do we even need these or can we handle these some other way
// MARK: Asset Player Observers
extension AssetPlayer {
    private func addPlayerObservers() {
//        addObserver(self, forKeyPath: #keyPath(AssetPlayer.player.currentItem.duration), options: [.new, .initial], context: &AssetPlayerKVOContext)
//        addObserver(self, forKeyPath: #keyPath(AssetPlayer.player.rate), options: [.new, .initial], context: &AssetPlayerKVOContext)
//        addObserver(self, forKeyPath: #keyPath(AssetPlayer.player.currentItem.status), options: [.new, .initial], context: &AssetPlayerKVOContext)
    }

    private func removePlayerObservers() {
//        // We have to manually remove these observers in < 9.0 and if we are in tests
//        if #available(iOS 9.0, *), !UIApplication.isInTest() {
//        } else {
//            removeObserver(self, forKeyPath: #keyPath(AssetPlayer.player.currentItem.duration), context: &AssetPlayerKVOContext)
//            removeObserver(self, forKeyPath: #keyPath(AssetPlayer.player.rate), context: &AssetPlayerKVOContext)
//            removeObserver(self, forKeyPath: #keyPath(AssetPlayer.player.currentItem.status), context: &AssetPlayerKVOContext)
//        }
    }
}

extension AssetPlayer {
    // Player buffer observers
    private func addPlayerItemObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleAVPlayerItemDidPlayToEndTimeNotification(notification:)), name: .AVPlayerItemDidPlayToEndTime, object: avPlayerItem)

        playbackBufferEmptyObserver = avPlayerItem?.observe(\.isPlaybackBufferEmpty, options: [.new, .old], changeHandler: { (playerItem, change) in
            self.handleBufferEmptyChange()
        })

        playbackLikelyToKeepUpObserver = avPlayerItem?.observe(\.isPlaybackLikelyToKeepUp, options: [.new, .old], changeHandler: { (playerItem, change) in
            self.handleLikelyToKeepUpChange()
        })

        loadedTimeRangesObserver = avPlayerItem?.observe(\.loadedTimeRanges, options: [.new, .old], changeHandler: { (playerItem, change) in
            self.handleLoadedTimeRangesChange()
        })
    }

    private func removePlayerItemObservers() {
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: avPlayerItem)

        playbackBufferEmptyObserver?.invalidate()
        playbackLikelyToKeepUpObserver?.invalidate()
        loadedTimeRangesObserver?.invalidate()
    }

    private func handleBufferEmptyChange() {
        // No need to use this keypath if we are playing local video
        guard !isPlayingLocalAsset else { return }

        // PlayerEmptyBufferKey
        if let item = self.avPlayerItem {
            if item.isPlaybackBufferEmpty && !item.isPlaybackBufferFull {
                self.state = .buffering
            }
        }
    }

    private func handleLikelyToKeepUpChange() {
        // No need to use this keypath if we are playing local video
        guard !isPlayingLocalAsset else { return }

        // PlayerKeepUpKey
        if let item = self.avPlayerItem {
            if item.isPlaybackLikelyToKeepUp {
                self.delegate?.playerIsLikelyToKeepUp(self)
            }
        }
    }

    private func handleLoadedTimeRangesChange() {
        // @TODO: fix buffering calculations and empty buffer actually being full buffer

        // No need to use this keypath if we are playing local video
        guard !isPlayingLocalAsset else { return }

        // PlayerLoadedTimeRangesKey
        if let item = self.avPlayerItem {
            let timeRanges = item.loadedTimeRanges
            if let timeRange = timeRanges.first?.timeRangeValue {
                let bufferedTime = Double(CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration)))
                self.bufferedTime = bufferedTime

                // Smart Value check for buffered time to switch to playing state or to buffering state

                // Acceptable buffer is {percent} of total asset duration with a dampening factor
                // @TODO: There is a bit better buffering calculation we could do here
                let percent = 100.0
                let percentageOfDuration = self.duration * (percent / 100.0)
//                // @TODO: Figure out dynamic dampening
//                let acceptableBufferedTime = pow(percentageOfDuration, (1.0/2.0))
                let acceptableBufferedTime = percentageOfDuration
                let isBufferedEnough = (bufferedTime - self.currentTime) > acceptableBufferedTime || bufferedTime >= self.duration

                switch isBufferedEnough {
                case true:
                    // Only switch to playing state if we are in buffering state and our previous state was playing
                    if self.state == .buffering, previousState == .playing {
                        self.state = previousState
                    }
                case false:
                    if self.state != .buffering, self.state != .paused {
                        self.state = .buffering
                    }
                }
            }
        }
    }
}

public enum AssetPlayerActions {
    case setup(with: AssetProtocol, startMuted: Bool)
    case play
    case pause
    case seekToTimeInSeconds(time: Double)
    case changePlayerPlaybackRate(to: Float)
    case changeIsPlayingLocalAsset(to: Bool)
    case changeShouldLoop(to: Bool)
    case changeStartTimeForLoop(to: Double)
    case changeEndTimeForLoop(to: Double)
    case changeIsMuted(to: Bool)
}
