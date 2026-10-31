const HEALTHY = "healthy";
const MIN_AGREEMENT = 0.5;
const TOP_IMPACTS = 3;

// Collapses per-reading predictions into one diagnosis for the window.
// The model classifies each reading on its own, so the window verdict is the
// majority class. A window is "uncertain" when the readings disagree
// (the winning class holds half the votes or fewer) or has low mean confidence.
// explanation averages |SHAP| over the readings that voted for the winner,
// using the top-3 contributions the model service returns per reading.
function aggregate(Prediction[] predictions, float lowConfidenceThreshold) returns Diagnosis {
    map<int> votes = {};
    foreach Prediction p in predictions {
        votes[p.predicted_class] = (votes[p.predicted_class] ?: 0) + 1;
    }

    string winner = "";
    int winnerVotes = 0;
    foreach string cls in votes.keys() {
        int count = votes.get(cls);
        if count > winnerVotes {
            winnerVotes = count;
            winner = cls;
        }
    }

    float confidenceSum = 0.0;
    int faultCount = 0;
    map<float> shapSums = {};
    foreach Prediction p in predictions {
        if p.predicted_class != HEALTHY {
            faultCount += 1;
        }
        if p.predicted_class == winner {
            confidenceSum += p.confidence;
            foreach FeatureContribution contribution in p.top_features {
                shapSums[contribution.feature] = (shapSums[contribution.feature] ?: 0.0) + float:abs(contribution.shap_value);
            }
        }
    }

    int total = predictions.length();
    float confidence = confidenceSum / <float>winnerVotes;
    float agreement = <float>winnerVotes / <float>total;

    FeatureImpact[] impacts = [];
    foreach string feature in shapSums.keys() {
        impacts.push({feature, mean_abs_shap: shapSums.get(feature) / <float>winnerVotes});
    }
    FeatureImpact[] topImpacts = from FeatureImpact impact in impacts
        order by impact.mean_abs_shap descending
        limit TOP_IMPACTS
        select impact;

    string status;
    if agreement <= MIN_AGREEMENT || confidence < lowConfidenceThreshold {
        status = "uncertain";
    } else if winner == HEALTHY {
        status = "healthy";
    } else {
        status = "fault_detected";
    }

    return {
        status,
        diagnosis: winner,
        confidence,
        agreement,
        fault_fraction: <float>faultCount / <float>total,
        window_size: total,
        votes,
        explanation: topImpacts
    };
}
