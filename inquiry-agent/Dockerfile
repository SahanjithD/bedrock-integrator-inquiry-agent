# AgentCore Runtime runs ARM64 containers. Build with:
#   docker buildx build --platform linux/arm64 -t inquiry-agent .
#
# The build stage runs on the build machine's own platform (the JAR is platform independent).
# TODO(verify): image tags for Ballerina 2201.14.0 and the Java runtime it targets (Java 25).
FROM --platform=$BUILDPLATFORM ballerina/ballerina:2201.14.0 AS build
WORKDIR /home/ballerina/src
COPY --chown=ballerina:ballerina . .
RUN bal build

# The OpenTelemetry Collector that sends the agent's traces to CloudWatch (otel/collector.yaml).
FROM otel/opentelemetry-collector-contrib:0.161.0 AS collector

FROM eclipse-temurin:25-jre
RUN groupadd --system app && useradd --system --gid app app
WORKDIR /app
COPY --from=build /home/ballerina/src/target/bin/inquiry_agent.jar /app/app.jar
COPY --from=collector /otelcol-contrib /app/otelcol
COPY otel/collector.yaml /app/collector.yaml
# Ballerina reads Config.toml from the working directory: tracing and log settings only.
COPY otel/observability.toml /app/Config.toml
COPY --chmod=755 otel/start.sh /app/start.sh
USER app
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
