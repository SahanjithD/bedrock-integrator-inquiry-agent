# AgentCore Runtime runs ARM64 containers. Build with:
#   docker buildx build --platform linux/arm64 -t inquiry-agent .
#
# The build stage runs on the build machine's own platform (the JAR is platform independent).
# TODO(verify): image tags for Ballerina 2201.14.0 and the Java runtime it targets (Java 25).
FROM --platform=$BUILDPLATFORM ballerina/ballerina:2201.14.0 AS build
WORKDIR /home/ballerina/src
COPY --chown=ballerina:ballerina . .
RUN bal build

FROM eclipse-temurin:25-jre
RUN groupadd --system app && useradd --system --gid app app
WORKDIR /app
COPY --from=build /home/ballerina/src/target/bin/inquiry_agent.jar /app/app.jar
USER app
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
