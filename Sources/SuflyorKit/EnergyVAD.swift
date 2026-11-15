import Foundation

/// Фрагмент речи, вырезанный VAD. Время — в секундах от начала потока канала,
/// считается по числу сэмплов, а не по часам: так не плывёт при задержках колбэков.
public struct SpeechSegment: Equatable {
    public var samples: [Float]
    public var startTime: Double
    public var endTime: Double
    public var duration: Double { endTime - startTime }
}

/// Простой VAD по энергии (RMS) на кадрах 20 мс.
/// Нейросетевой VAD не берём: на этапе 1 нужен только разрез на фразы для whisper,
/// а отсев мусора делает фильтр текста.
public final class EnergyVAD {
    public struct Config {
        public var sampleRate: Double = 16_000
        public var frameDuration: Double = 0.02
        /// Пауза, после которой фраза считается законченной.
        public var silenceToEnd: Double = 0.6
        /// Жёсткий потолок длины фразы: длинный монолог режем, чтобы текст шёл без задержки.
        public var maxSegment: Double = 12
        /// Короче — щелчки и кашель, whisper на них галлюцинирует.
        public var minSpeech: Double = 0.3
        /// Сколько тишины захватить перед началом речи, чтобы не срезать первый слог.
        public var preRoll: Double = 0.2
        /// Сколько хвостовой тишины оставить во фрагменте.
        public var keepTrailingSilence: Double = 0.2
        /// Нижний порог RMS: ниже — всегда тишина, даже если шумовой фон нулевой.
        public var minThreshold: Float = 0.008
        /// Речь — когда RMS выше фона во столько раз.
        public var noiseFactor: Float = 3
        public init() {}
    }

    public let config: Config
    private let frameSize: Int
    private var pending: [Float] = []          // остаток, не набравший целый кадр
    private var processedSamples = 0           // сколько сэмплов уже разложено по кадрам
    private var noiseFloor: Float = 0.002
    private var preRollBuf: [Float] = []
    private var current: [Float] = []
    private var currentStart = 0               // индекс первого сэмпла текущего фрагмента
    private var voicedSamples = 0
    private var silenceRun = 0                 // подряд идущие тихие сэмплы в конце фрагмента
    private var inSpeech = false

    public init(config: Config = Config()) {
        self.config = config
        self.frameSize = max(1, Int(config.sampleRate * config.frameDuration))
    }

    /// Скармливает очередную порцию моно-сэмплов, возвращает законченные фрагменты.
    public func process(_ samples: [Float]) -> [SpeechSegment] {
        pending.append(contentsOf: samples)
        var out: [SpeechSegment] = []
        var offset = 0
        while pending.count - offset >= frameSize {
            let frame = Array(pending[offset..<offset + frameSize])
            offset += frameSize
            if let seg = handle(frame: frame) { out.append(seg) }
        }
        pending.removeFirst(offset)
        return out
    }

    /// Закрывает незаконченную фразу (конец потока).
    public func flush() -> SpeechSegment? {
        guard inSpeech else { return nil }
        return finish(trimSilence: true)
    }

    private func handle(frame: [Float]) -> SpeechSegment? {
        let frameStart = processedSamples
        processedSamples += frame.count
        let rms = Self.rms(frame)
        let threshold = max(config.minThreshold, noiseFloor * config.noiseFactor)
        let voiced = rms > threshold

        if !inSpeech {
            if voiced {
                inSpeech = true
                current = preRollBuf + frame
                currentStart = frameStart - preRollBuf.count
                preRollBuf.removeAll()
                voicedSamples = frame.count
                silenceRun = 0
            } else {
                // Фон учим только на тишине, иначе громкая речь задерёт порог.
                noiseFloor = noiseFloor * 0.95 + rms * 0.05
                preRollBuf.append(contentsOf: frame)
                let maxPre = Int(config.preRoll * config.sampleRate)
                if preRollBuf.count > maxPre { preRollBuf.removeFirst(preRollBuf.count - maxPre) }
            }
            return nil
        }

        current.append(contentsOf: frame)
        if voiced {
            voicedSamples += frame.count
            silenceRun = 0
        } else {
            silenceRun += frame.count
        }

        if Double(silenceRun) >= config.silenceToEnd * config.sampleRate {
            return finish(trimSilence: true)
        }
        if Double(current.count) >= config.maxSegment * config.sampleRate {
            // Режем посреди речи: следующий фрагмент начнётся со следующего кадра, без preroll,
            // чтобы звук не дублировался в двух запросах.
            // Если дальше окажется тишина, хвост отсеется по minSpeech.
            let seg = finish(trimSilence: false)
            inSpeechContinue()
            return seg
        }
        return nil
    }

    private func inSpeechContinue() {
        inSpeech = true
        current = []
        currentStart = processedSamples
        voicedSamples = 0
        silenceRun = 0
    }

    private func finish(trimSilence: Bool) -> SpeechSegment? {
        var samples = current
        if trimSilence {
            let keep = Int(config.keepTrailingSilence * config.sampleRate)
            let cut = max(0, silenceRun - keep)
            if cut > 0 { samples.removeLast(min(cut, samples.count)) }
        }
        let enoughSpeech = Double(voicedSamples) >= config.minSpeech * config.sampleRate
        let start = currentStart
        inSpeech = false
        current = []
        voicedSamples = 0
        silenceRun = 0
        guard enoughSpeech, !samples.isEmpty else { return nil }
        let sr = config.sampleRate
        return SpeechSegment(
            samples: samples,
            startTime: Double(start) / sr,
            endTime: Double(start + samples.count) / sr
        )
    }

    static func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(frame.count)).squareRoot()
    }
}
