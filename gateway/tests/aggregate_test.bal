import ballerina/test;

function prediction(string cls, float confidence) returns Prediction => {
    predicted_class: cls,
    confidence,
    probabilities: {},
    top_features: [{feature: "Vdc", shap_value: -2.0}, {feature: "ia", shap_value: 1.0}]
};

@test:Config {}
function allHealthyWindow() {
    Diagnosis result = aggregate([prediction("healthy", 0.75), prediction("healthy", 0.75)], 0.6);
    test:assertEquals(result.status, "healthy");
    test:assertEquals(result.fault_fraction, 0.0);
    test:assertEquals(result.window_size, 2);
}

@test:Config {}
function majorityFaultWindow() {
    Prediction[] window = [
        prediction("fault_6", 0.75),
        prediction("fault_6", 0.75),
        prediction("fault_6", 0.75),
        prediction("healthy", 0.75)
    ];
    Diagnosis result = aggregate(window, 0.6);
    test:assertEquals(result.status, "fault_detected");
    test:assertEquals(result.diagnosis, "fault_6");
    test:assertEquals(result.confidence, 0.75);
    test:assertEquals(result.agreement, 0.75);
    test:assertEquals(result.fault_fraction, 0.75);
    test:assertEquals(result.explanation[0].feature, "Vdc");
    test:assertEquals(result.explanation[0].mean_abs_shap, 2.0);
}

@test:Config {}
function disagreeingWindowIsUncertain() {
    Prediction[] window = [
        prediction("fault_1", 0.75),
        prediction("fault_2", 0.75),
        prediction("fault_3", 0.75)
    ];
    test:assertEquals(aggregate(window, 0.6).status, "uncertain");
}

@test:Config {}
function tiedWindowIsUncertain() {
    Diagnosis result = aggregate([prediction("fault_6", 0.75), prediction("healthy", 0.75)], 0.6);
    test:assertEquals(result.status, "uncertain");
}

@test:Config {}
function lowConfidenceWindowIsUncertain() {
    Diagnosis result = aggregate([prediction("fault_4", 0.5), prediction("fault_4", 0.5)], 0.6);
    test:assertEquals(result.status, "uncertain");
    test:assertEquals(result.diagnosis, "fault_4");
}
