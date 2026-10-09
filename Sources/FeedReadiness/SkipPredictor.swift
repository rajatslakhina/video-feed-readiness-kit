import Foundation

/// A tiny online logistic-regression model, trained on-device during the
/// session, that predicts whether the user will skip the *next* item.
///
/// Why a model at all: prefetch depth is a bet on future attention. A user
/// who flicks past 90% of items wastes most of a 6-second prefetch; a user
/// who watches to the end stalls on a 1.5-second one. A fixed constant is
/// wrong for both. This model sets the per-item prefetch depth.
///
/// What it is not: there is no neural network, no server, and no persisted
/// profile. Four weights, updated by one SGD step per observed item, reset
/// with the session. Inputs are sanitised so NaN/inf from a broken player
/// clock can never poison the weights.
public struct SkipPredictor: Sendable {
    /// What the engine learns from after the user leaves an item.
    public struct Observation: Sendable, Equatable {
        /// Fraction of the item watched, 0...1 (clamped; non-finite -> 0).
        public let watchFraction: Double
        /// Speed of the swipe that left the item, points per second.
        public let swipeVelocity: Double

        public init(watchFraction: Double, swipeVelocity: Double) {
            self.watchFraction = watchFraction.sanitized(in: 0 ... 1, fallback: 0)
            self.swipeVelocity = swipeVelocity.sanitized(in: 0 ... 100_000, fallback: 0)
        }
    }

    /// Below this watch fraction an item counts as skipped.
    public let skipFraction: Double
    public let learningRate: Double
    public let historyLimit: Int
    /// Velocity that maps to feature value 1.0.
    public let velocityScale: Double

    public private(set) var weights: [Double]
    public private(set) var history: [Observation] = []
    public private(set) var observations: Int = 0

    /// One learning step: new weights from (weights, features, prediction
    /// error, learning rate). Internal so tests can substitute a deliberately
    /// broken rule and prove the learning tests would catch it.
    typealias LearningRule = @Sendable (_ weights: [Double], _ features: [Double],
                                        _ error: Double, _ rate: Double) -> [Double]

    /// Gradient descent on the log-loss: w += rate * (label - p) * x.
    static let gradientStep: LearningRule = { weights, features, error, rate in
        weights.indices.map { index in
            index < features.count ? weights[index] + rate * error * features[index] : weights[index]
        }
    }

    let rule: LearningRule

    public init(skipFraction: Double = 0.25, learningRate: Double = 0.5,
                historyLimit: Int = 8, velocityScale: Double = 3_000) {
        self.init(skipFraction: skipFraction, learningRate: learningRate, historyLimit: historyLimit,
                  velocityScale: velocityScale, rule: Self.gradientStep)
    }

    init(skipFraction: Double = 0.25, learningRate: Double = 0.5, historyLimit: Int = 8,
         velocityScale: Double = 3_000, rule: @escaping LearningRule) {
        self.skipFraction = skipFraction.sanitized(in: 0 ... 1, fallback: 0.25)
        self.learningRate = learningRate.sanitized(in: 0 ... 10, fallback: 0.5)
        self.historyLimit = max(1, historyLimit)
        self.velocityScale = velocityScale.sanitized(in: 1 ... 1_000_000, fallback: 3_000)
        self.weights = [0, 0, 0, 0]
        self.rule = rule
    }

    static let weightBound = 8.0

    /// Feature vector from history only (it must be computable *before* the
    /// next item is seen): bias, last watch fraction, mean watch fraction,
    /// normalised last swipe velocity. All in 0...1.
    public var features: [Double] {
        guard let last = history.last else { return [1, 0.5, 0.5, 0] }
        let mean = history.reduce(0) { $0 + $1.watchFraction } / Double(max(1, history.count))
        let velocity = min(1, last.swipeVelocity / velocityScale)
        return [1, last.watchFraction, mean, velocity]
    }

    /// Probability, in (0, 1), that the next item is skipped. Exactly 0.5
    /// before any learning, because all weights start at zero.
    public var skipProbability: Double {
        Self.sigmoid(zip(weights, features).reduce(0) { $0 + $1.0 * $1.1 })
    }

    /// One SGD step on the log-loss: the prediction made from the history
    /// *before* `observation` is scored against whether it was a skip.
    public mutating func learn(_ observation: Observation) {
        let x = features
        let predicted = Self.sigmoid(zip(weights, x).reduce(0) { $0 + $1.0 * $1.1 })
        let label: Double = observation.watchFraction < skipFraction ? 1 : 0
        let updated = rule(weights, x, label - predicted, learningRate)
        // Whatever the rule returns, weights stay finite, bounded and the
        // same length (a short result keeps the old weight).
        weights = weights.indices.map { index in
            let value = index < updated.count ? updated[index] : weights[index]
            return value.sanitized(in: -Self.weightBound ... Self.weightBound, fallback: 0)
        }
        history.append(observation)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        Saturating.increment(&observations)
    }

    static func sigmoid(_ z: Double) -> Double {
        let safe = z.sanitized(in: -40 ... 40, fallback: 0)
        return 1 / (1 + exp(-safe))
    }
}
