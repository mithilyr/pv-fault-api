// Request: one electrical reading, the 14 features the thesis model was trained on.
type Reading record {|
    float current_a;
    float voltage_v;
    float Vdc;
    float ia;
    float ib;
    float ic;
    float va;
    float vb;
    float vc;
    float Iabc;
    float If;
    float Vabc;
    float Vf;
    string operation_mode;
|};

type DiagnoseRequest record {|
    Reading[] readings;
|};

// Model service response (see model-service/app.py).
type FeatureContribution record {|
    string feature;
    float shap_value;
|};

type Prediction record {|
    string predicted_class;
    float confidence;
    map<float> probabilities;
    FeatureContribution[] top_features;
|};

type PredictResponse record {|
    Prediction[] predictions;
|};

// Gateway response: one diagnosis for the whole window of readings.
type FeatureImpact record {|
    string feature;
    float mean_abs_shap;
|};

type Diagnosis record {|
    string status;
    string diagnosis;
    float confidence;
    float agreement;
    float fault_fraction;
    int window_size;
    map<int> votes;
    FeatureImpact[] explanation;
|};
