#!/bin/sh
# Runs the OpenTelemetry Collector and the agent side by side. On shutdown the agent stops first,
# so the collector can still export its last spans. If the collector stops on its own (for
# example without AWS credentials on a local run), the agent keeps running without tracing.

# The collector's configuration names the Region; scripts/04-agent.sh sets it for the agent.
export AWS_REGION="${AWS_REGION:-${BAL_CONFIG_VAR_AWSREGION:-us-east-1}}"

/app/otelcol --config=/app/collector.yaml &
COLLECTOR=$!
java -XX:+ExitOnOutOfMemoryError -jar /app/app.jar &
APP=$!

stop() {
    kill -TERM "$APP" 2>/dev/null
    wait "$APP"
    STATUS=$?
    kill -TERM "$COLLECTOR" 2>/dev/null
    wait "$COLLECTOR"
    exit "$STATUS"
}
trap stop TERM INT

wait "$APP"
STATUS=$?
kill -TERM "$COLLECTOR" 2>/dev/null
wait "$COLLECTOR"
exit "$STATUS"
