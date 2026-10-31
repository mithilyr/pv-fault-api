import ballerina/http;
import ballerina/log;

configurable string modelServiceUrl = "http://localhost:8000";
configurable int port = 9090;
configurable int maxReadings = 5000;
configurable float lowConfidenceThreshold = 0.6;

final http:Client modelClient = check new (modelServiceUrl, timeout = 30);

service /api/v1 on new http:Listener(port) {

    resource function get health() returns json {
        return {status: "ok"};
    }

    // Validates a window of readings, scores it with the model service and
    // returns a single diagnosis with the features that drove it.
    resource function post diagnose(DiagnoseRequest request)
            returns Diagnosis|http:BadRequest|http:BadGateway {
        int count = request.readings.length();
        if count == 0 {
            return <http:BadRequest>{body: {message: "readings must not be empty"}};
        }
        if count > maxReadings {
            return <http:BadRequest>{body: {message: string `at most ${maxReadings} readings per request`}};
        }
        foreach Reading reading in request.readings {
            if reading.operation_mode != "MPPT" && reading.operation_mode != "IPPT" {
                return <http:BadRequest>{body: {message: "operation_mode must be MPPT or IPPT"}};
            }
        }

        PredictResponse|error scored = modelClient->post("/predict", request);
        if scored is error {
            log:printError("model service call failed", 'error = scored);
            return <http:BadGateway>{body: {message: "model service unavailable"}};
        }
        return aggregate(scored.predictions, lowConfidenceThreshold);
    }
}
